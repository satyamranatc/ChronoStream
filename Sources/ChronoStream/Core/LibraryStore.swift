import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public var folders: [AuthorizedFolder] = []
    public var collections: [CustomCollection] = []
    public var items: [MediaItem] = []
    public var duplicateItemIDs: Set<String> = []

    public var selection: SidebarSelection = .dashboard
    public var activeItem: MediaItem?
    public var quickPreviewItem: MediaItem?
    public var searchQuery: String = ""
    public var viewMode: ExplorerViewMode = .grid
    public var sortOrder: MediaSortOrder = .dateDesc

    public enum ClipboardMode: Sendable {
        case copy
        case cut
    }

    public var isScanning: Bool = false
    public var scanStatusText: String = ""
    public var clipboardURLs: [URL] = []
    public var clipboardMode: ClipboardMode = .copy
    public var fileOpMessage: String?
    public var monitorFoldersEnabled: Bool = false {
        didSet {
            persistState()
            rebuildFolderWatchers()
        }
    }
    public var slideshowInterval: Double = 4.0 {
        didSet { persistState() }
    }
    public var defaultPlaybackRate: Double = 1.0 {
        didSet { persistState() }
    }

    private var favorites: Set<String> = []
    private var playbackPositions: [String: Double] = [:]
    private var lastOpenedDates: [String: Date] = [:]
    private var folderWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var scanTask: Task<Void, Never>?

    public init() {
        let state = SecurityBookmarkStore.shared.loadState()
        self.folders = state.folders
        self.collections = state.collections
        self.favorites = state.favorites
        self.playbackPositions = state.playbackPositions
        self.lastOpenedDates = state.lastOpenedDates
        self.monitorFoldersEnabled = state.monitorFoldersEnabled
        self.slideshowInterval = state.slideshowInterval
        self.defaultPlaybackRate = state.defaultPlaybackRate

        if !folders.isEmpty {
            rescanAllFolders()
        }
        rebuildFolderWatchers()
    }

    public var filteredItems: [MediaItem] {
        var list: [MediaItem]
        switch selection {
        case .smart(let smart):
            switch smart {
            case .all:
                list = items
            case .continueWatching:
                list = items.filter { ($0.kind == .video || $0.kind == .audio) && $0.lastPosition > 5 }
                    .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            case .videos:
                list = items.filter { $0.kind == .video }
            case .audio:
                list = items.filter { $0.kind == .audio }
            case .photos:
                list = items.filter { $0.kind == .image }
            case .documents:
                list = items.filter { $0.kind == .pdf }
            case .favorites:
                list = items.filter { $0.isFavorite }
            case .recent:
                list = items.filter { $0.lastOpened != nil }
                    .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
            case .duplicates:
                list = items.filter { duplicateItemIDs.contains($0.id) }
            }
        case .folder(let folderPath):
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            list = items.filter { $0.path.hasPrefix(prefix) }
        case .collection(let id):
            let ids = Set(collections.first(where: { $0.id == id })?.itemIDs ?? [])
            list = items.filter { ids.contains($0.id) }
        case .photoStudio, .videoStudio, .documentStudio, .dashboard, .wifiShare:
            list = []
        }

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.kind.displayName.lowercased().contains(q)
                    || $0.fileExtension.lowercased().contains(q)
            }
        }

        switch selection {
        case .smart(.recent), .smart(.continueWatching):
            return list
        default:
            return sortItems(list)
        }
    }

    public func count(for smart: SmartCollection) -> Int {
        switch smart {
        case .all: return items.count
        case .continueWatching: return items.filter { ($0.kind == .video || $0.kind == .audio) && $0.lastPosition > 5 }.count
        case .videos: return items.filter { $0.kind == .video }.count
        case .audio: return items.filter { $0.kind == .audio }.count
        case .photos: return items.filter { $0.kind == .image }.count
        case .documents: return items.filter { $0.kind == .pdf }.count
        case .favorites: return items.filter { $0.isFavorite }.count
        case .recent: return items.filter { $0.lastOpened != nil }.count
        case .duplicates: return duplicateItemIDs.count
        }
    }

    private func sortItems(_ list: [MediaItem]) -> [MediaItem] {
        switch sortOrder {
        case .nameAsc:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateDesc:
            return list.sorted { $0.modifiedDate > $1.modifiedDate }
        case .sizeDesc:
            return list.sorted { $0.fileSize > $1.fileSize }
        case .kind:
            return list.sorted {
                if $0.kind == $1.kind {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    // MARK: - User-Selected File & Folder Access (Least Privilege)

    public func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Media Folder"
        panel.message = "ChronoStream only accesses folders you explicitly authorize."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                addFolder(url)
            }
        }
    }

    public func promptOpenFiles() {
        let panel = NSOpenPanel()
        panel.title = "Open Media"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            handleDroppedURLs(panel.urls, openFirst: true)
        }
    }

    public func addFolder(_ url: URL) {
        let std = url.standardizedFileURL
        guard !folders.contains(where: { $0.id == std.path }) else {
            selection = .folder(std.path)
            return
        }
        let bookmark = SecurityBookmarkStore.shared.createBookmark(for: std)
        let folder = AuthorizedFolder(url: std, bookmarkData: bookmark)
        folders.append(folder)
        selection = .folder(folder.id)
        persistState()
        rebuildFolderWatchers()
        rescanAllFolders()
    }

    public func removeFolder(_ folder: AuthorizedFolder) {
        SecurityBookmarkStore.shared.stopAccess(for: folder.id)
        folders.removeAll { $0.id == folder.id }
        if selection == .folder(folder.id) {
            selection = .smart(.all)
        }
        persistState()
        rebuildFolderWatchers()
        rescanAllFolders()
    }

    public func handleDroppedURLs(_ urls: [URL], openFirst: Bool = false) {
        var firstMedia: MediaItem?
        var addedFolder = false
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                addFolder(url)
                addedFolder = true
            } else if let kind = MediaFormatRegistry.kind(for: url) {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let item = MediaItem(
                    url: url,
                    kind: kind,
                    fileSize: Int64(vals?.fileSize ?? 0),
                    modifiedDate: vals?.contentModificationDate ?? Date(),
                    isFavorite: favorites.contains(url.standardizedFileURL.path),
                    lastPosition: playbackPositions[url.standardizedFileURL.path] ?? 0,
                    lastOpened: lastOpenedDates[url.standardizedFileURL.path]
                )
                if !items.contains(where: { $0.id == item.id }) {
                    items.insert(item, at: 0)
                }
                if firstMedia == nil { firstMedia = item }
            }
        }

        if openFirst, let first = firstMedia {
            openItem(first)
        } else if !addedFolder, let first = firstMedia {
            openItem(first)
        }
    }

    // MARK: - Async Incremental Library Scanning

    public func rescanAllFolders() {
        scanTask?.cancel()
        let foldersSnapshot = folders
        let favs = favorites
        let positions = playbackPositions
        let opened = lastOpenedDates

        if foldersSnapshot.isEmpty {
            items = []
            duplicateItemIDs = []
            isScanning = false
            scanStatusText = ""
            return
        }

        isScanning = true
        scanStatusText = "Scanning \(foldersSnapshot.count) folder(s)…"

        scanTask = Task.detached(priority: .utility) {
            var discovered: [MediaItem] = []
            var seen = Set<String>()
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

            for folder in foldersSnapshot {
                if Task.isCancelled { return }
                let resolvedURL = SecurityBookmarkStore.shared.resolveAndStartAccess(folder: folder)
                guard let enumerator = fm.enumerator(
                    at: resolvedURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled { return }
                    guard let kind = MediaFormatRegistry.kind(for: fileURL), kind != .textFile else { continue }
                    guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)),
                          vals.isRegularFile == true else { continue }
                    let stdPath = fileURL.standardizedFileURL.path
                    if seen.insert(stdPath).inserted {
                        discovered.append(
                            MediaItem(
                                url: fileURL,
                                kind: kind,
                                fileSize: Int64(vals.fileSize ?? 0),
                                modifiedDate: vals.contentModificationDate ?? .distantPast,
                                isFavorite: favs.contains(stdPath),
                                lastPosition: positions[stdPath] ?? 0,
                                lastOpened: opened[stdPath]
                            )
                        )
                    }
                }
            }

            // Fast duplicate detection: group by fileSize first, then partial 128 KB SHA-256
            var bySize: [Int64: [MediaItem]] = [:]
            for item in discovered where item.fileSize > 0 {
                bySize[item.fileSize, default: []].append(item)
            }
            var dupIDs = Set<String>()
            for (size, group) in bySize where group.count > 1 {
                if Task.isCancelled { return }
                var byHash: [String: [String]] = [:]
                for item in group {
                    if let h = SecurityBookmarkStore.fastPartialHash(for: item.url, fileSize: size) {
                        byHash[h, default: []].append(item.id)
                    }
                }
                for (_, ids) in byHash where ids.count > 1 {
                    dupIDs.formUnion(ids)
                }
            }

            let finalItems = discovered
            let finalDups = dupIDs
            await MainActor.run {
                self.items = finalItems
                self.duplicateItemIDs = finalDups
                self.isScanning = false
                self.scanStatusText = "\(finalItems.count) items"
            }
        }
    }

    // MARK: - Item Actions, Collections, History, Positions

    public func openItem(_ item: MediaItem) {
        let now = Date()
        lastOpenedDates[item.id] = now
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].lastOpened = now
            activeItem = items[idx]
        } else {
            var copy = item
            copy.lastOpened = now
            activeItem = copy
        }
        persistState()
    }

    public func toggleFavorite(_ item: MediaItem) {
        if favorites.contains(item.id) {
            favorites.remove(item.id)
        } else {
            favorites.insert(item.id)
        }
        let isFav = favorites.contains(item.id)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isFavorite = isFav
        }
        if activeItem?.id == item.id {
            activeItem?.isFavorite = isFav
        }
        persistState()
    }

    public func updatePlaybackPosition(for itemID: String, position: Double, duration: Double?) {
        let clamped = max(0, position)
        playbackPositions[itemID] = clamped
        if let idx = items.firstIndex(where: { $0.id == itemID }) {
            items[idx].lastPosition = clamped
            if let d = duration, d > 0 { items[idx].duration = d }
        }
        if activeItem?.id == itemID {
            activeItem?.lastPosition = clamped
        }
        persistState()
    }

    public func createCollection(name: String, symbol: String = "folder") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let col = CustomCollection(name: trimmed, symbol: symbol)
        collections.append(col)
        selection = .collection(col.id)
        persistState()
    }

    public func deleteCollection(_ col: CustomCollection) {
        collections.removeAll { $0.id == col.id }
        if selection == .collection(col.id) {
            selection = .smart(.all)
        }
        persistState()
    }

    public func addItem(_ item: MediaItem, to collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if !collections[idx].itemIDs.contains(item.id) {
            collections[idx].itemIDs.append(item.id)
            persistState()
        }
    }

    public func removeItem(_ item: MediaItem, from collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[idx].itemIDs.removeAll { $0 == item.id }
        persistState()
    }

    public func revealInFinder(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Finder-Style File Operations (Cut, Copy, Paste, Rename, Duplicate, Move, Trash)

    private func flashFileOp(_ message: String) {
        fileOpMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.fileOpMessage == message {
                self.fileOpMessage = nil
            }
        }
    }

    private func uniqueDestinationURL(in folder: URL, filename: String) -> URL {
        let fm = FileManager.default
        let baseURL = folder.appendingPathComponent(filename)
        guard fm.fileExists(atPath: baseURL.path) else { return baseURL }
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        var idx = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(idx)" : "\(stem) \(idx).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            idx += 1
        }
    }

    public var currentFolderURL: URL? {
        if case .folder(let path) = selection {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public var hasPasteableFiles: Bool {
        if !clipboardURLs.isEmpty { return true }
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return true
        }
        return false
    }

    public func copyItems(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let urls = targets.map(\.url)
        clipboardURLs = urls
        clipboardMode = .copy
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        flashFileOp("Copied \(targets.count == 1 ? targets[0].name : "\(targets.count) items")")
    }

    public func cutItems(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let urls = targets.map(\.url)
        clipboardURLs = urls
        clipboardMode = .cut
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        flashFileOp("Cut \(targets.count == 1 ? targets[0].name : "\(targets.count) items") — ready to paste")
    }

    public func copyPaths(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let text = targets.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashFileOp("Copied path\(targets.count > 1 ? "s" : "")")
    }

    public func pasteItems(into explicitFolder: URL? = nil) {
        let sourceURLs: [URL]
        let isCut: Bool
        if !clipboardURLs.isEmpty {
            sourceURLs = clipboardURLs
            isCut = (clipboardMode == .cut)
        } else if let pbURLs = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !pbURLs.isEmpty {
            sourceURLs = pbURLs
            isCut = false
        } else {
            return
        }

        let targetFolder: URL
        if let folder = explicitFolder ?? currentFolderURL {
            targetFolder = folder
        } else {
            let panel = NSOpenPanel()
            panel.title = isCut ? "Move Items To Folder" : "Paste Items Into Folder"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            targetFolder = picked
        }

        let fm = FileManager.default
        var succeeded = 0
        for src in sourceURLs {
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = uniqueDestinationURL(in: targetFolder, filename: src.lastPathComponent)
            do {
                if isCut {
                    if src.deletingLastPathComponent().standardizedFileURL == targetFolder.standardizedFileURL {
                        continue
                    }
                    try fm.moveItem(at: src, to: dest)
                    migrateMetadata(from: src.standardizedFileURL.path, to: dest.standardizedFileURL.path)
                } else {
                    try fm.copyItem(at: src, to: dest)
                }
                succeeded += 1
            } catch {
                // Skip failed file
            }
        }

        if isCut {
            clipboardURLs.removeAll()
            clipboardMode = .copy
        }
        if succeeded > 0 {
            rescanAllFolders()
            flashFileOp("\(isCut ? "Moved" : "Pasted") \(succeeded) item\(succeeded == 1 ? "" : "s") into \(targetFolder.lastPathComponent)")
        }
    }

    @discardableResult
    public func renameItem(_ item: MediaItem, to rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !trimmed.isEmpty else { return false }

        let oldURL = item.url
        let oldExt = oldURL.pathExtension
        let finalName: String
        if URL(fileURLWithPath: trimmed).pathExtension.isEmpty && !oldExt.isEmpty {
            finalName = "\(trimmed).\(oldExt)"
        } else {
            finalName = trimmed
        }
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(finalName)
        guard newURL.standardizedFileURL != oldURL.standardizedFileURL else { return true }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let oldID = item.id
            let newID = newURL.standardizedFileURL.path
            migrateMetadata(from: oldID, to: newID)

            let updated = MediaItem(
                url: newURL,
                kind: MediaFormatRegistry.kind(for: newURL) ?? item.kind,
                fileSize: item.fileSize,
                modifiedDate: Date(),
                duration: item.duration,
                isFavorite: favorites.contains(newID),
                lastPosition: playbackPositions[newID] ?? item.lastPosition,
                lastOpened: lastOpenedDates[newID] ?? item.lastOpened
            )
            if let idx = items.firstIndex(where: { $0.id == oldID }) {
                items[idx] = updated
            }
            if activeItem?.id == oldID {
                activeItem = updated
            }
            persistState()
            flashFileOp("Renamed to \(finalName)")
            return true
        } catch {
            flashFileOp("Rename failed: \(error.localizedDescription)")
            return false
        }
    }

    public func duplicateItems(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let fm = FileManager.default
        var created = 0
        for item in targets {
            let folder = item.url.deletingLastPathComponent()
            let ext = item.url.pathExtension
            let stem = item.url.deletingPathExtension().lastPathComponent
            let copyName = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
            let dest = uniqueDestinationURL(in: folder, filename: copyName)
            do {
                try fm.copyItem(at: item.url, to: dest)
                let newItem = MediaItem(
                    url: dest,
                    kind: item.kind,
                    fileSize: item.fileSize,
                    modifiedDate: Date(),
                    duration: item.duration
                )
                items.insert(newItem, at: 0)
                created += 1
            } catch {
                // Skip failed copy
            }
        }
        if created > 0 {
            flashFileOp("Duplicated \(created) item\(created == 1 ? "" : "s")")
        }
    }

    public func moveItems(_ targets: [MediaItem], to destinationFolder: URL) {
        guard !targets.isEmpty else { return }
        let fm = FileManager.default
        var moved = 0
        for item in targets {
            guard item.url.deletingLastPathComponent().standardizedFileURL != destinationFolder.standardizedFileURL else { continue }
            let dest = uniqueDestinationURL(in: destinationFolder, filename: item.url.lastPathComponent)
            do {
                try fm.moveItem(at: item.url, to: dest)
                migrateMetadata(from: item.id, to: dest.standardizedFileURL.path)
                moved += 1
            } catch {
                // Skip failed move
            }
        }
        if moved > 0 {
            rescanAllFolders()
            flashFileOp("Moved \(moved) item\(moved == 1 ? "" : "s") to \(destinationFolder.lastPathComponent)")
        }
    }

    public func promptMoveItems(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Move \(targets.count == 1 ? targets[0].name : "\(targets.count) Items") To…"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let dest = panel.url {
            moveItems(targets, to: dest)
        }
    }

    public func trashItems(_ targets: [MediaItem]) {
        guard !targets.isEmpty else { return }
        let fm = FileManager.default
        var trashedIDs = Set<String>()
        for item in targets {
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                trashedIDs.insert(item.id)
            } catch {
                // Skip failed trash
            }
        }
        if !trashedIDs.isEmpty {
            items.removeAll { trashedIDs.contains($0.id) }
            if let active = activeItem, trashedIDs.contains(active.id) {
                activeItem = nil
            }
            for id in trashedIDs {
                favorites.remove(id)
                playbackPositions.removeValue(forKey: id)
                lastOpenedDates.removeValue(forKey: id)
                for idx in collections.indices {
                    collections[idx].itemIDs.removeAll { $0 == id }
                }
            }
            persistState()
            flashFileOp("Moved \(trashedIDs.count) item\(trashedIDs.count == 1 ? "" : "s") to Trash")
        }
    }

    private func migrateMetadata(from oldID: String, to newID: String) {
        if favorites.remove(oldID) != nil {
            favorites.insert(newID)
        }
        if let pos = playbackPositions.removeValue(forKey: oldID) {
            playbackPositions[newID] = pos
        }
        if let date = lastOpenedDates.removeValue(forKey: oldID) {
            lastOpenedDates[newID] = date
        }
        for idx in collections.indices {
            if let itemIdx = collections[idx].itemIDs.firstIndex(of: oldID) {
                collections[idx].itemIDs[itemIdx] = newID
            }
        }
    }

    // MARK: - Optional Folder Monitoring (User Consent)

    private func rebuildFolderWatchers() {
        for (_, src) in folderWatchers { src.cancel() }
        folderWatchers.removeAll()
        guard monitorFoldersEnabled else { return }

        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            src.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.rescanAllFolders()
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            folderWatchers[folder.id] = src
        }
    }

    private func persistState() {
        var state = PersistedLibraryState()
        state.folders = folders
        state.collections = collections
        state.favorites = favorites
        state.playbackPositions = playbackPositions
        state.lastOpenedDates = lastOpenedDates
        state.monitorFoldersEnabled = monitorFoldersEnabled
        state.slideshowInterval = slideshowInterval
        state.defaultPlaybackRate = defaultPlaybackRate
        SecurityBookmarkStore.shared.saveState(state)
    }
}
