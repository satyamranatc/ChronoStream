import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LazyThumbnailView: View {
    let item: MediaItem
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Image(systemName: item.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.id) {
            image = await ThumbnailCache.shared.thumbnail(for: item, maxPixelSize: Int(max(size.width, size.height) * 2))
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovered ? 0.14 : 0.06))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(helpText)
        }
        .padding(.trailing, 4)
    }
}

public struct MainWindowView: View {
    @Bindable var store: LibraryStore
    @Bindable var videoController: VideoPlayerController
    @Bindable var audioController: AudioPlayerController

    @State private var showSidebar: Bool = true
    @State private var showNewCollectionSheet = false
    @State private var newCollectionName = ""
    @State private var isDropTargeted = false
    @State private var shareSession = LocalShareSession()
    @State private var itemsToShare: [MediaItem] = []
    @State private var showShareSheet = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("hasAskedDefaultPlayer") private var hasAskedDefaultPlayer = false
    @AppStorage("appThemeMode") private var appThemeMode: String = "light"
    @Environment(\.colorScheme) private var colorScheme
    @State private var showWelcomeSheet = false
    @State private var showDefaultBanner = false
    @State private var showDisplayPopover = false
    private let displayManager = DisplayManager.shared

    private let gridColumns = [GridItem(.adaptive(minimum: 175, maximum: 230), spacing: 16)]

    public init(store: LibraryStore, videoController: VideoPlayerController, audioController: AudioPlayerController) {
        self.store = store
        self.videoController = videoController
        self.audioController = audioController
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 244)
                    .background(colorScheme == .light ? Color(red: 0.975, green: 0.980, blue: 0.988) : Color(nsColor: .controlBackgroundColor))
                Divider()
            }

            ZStack(alignment: .bottom) {
                if store.selection == .dashboard && store.activeItem == nil {
                    DashboardView(store: store)
                } else if store.selection == .photoStudio {
                    PhotoStudioView(store: store)
                } else if store.selection == .videoStudio {
                    VideoStudioView(store: store)
                } else if store.selection == .documentStudio {
                    DocumentStudioView()
                } else if store.selection == .wifiShare {
                    WiFiShareHubView { receivedURL in
                        store.handleDroppedURLs([receivedURL], openFirst: true)
                    }
                } else if let active = store.activeItem {
                    activeViewer(for: active)
                } else {
                    explorerContent
                }

                // Persistent mini-player bar when audio is playing while browsing
                if store.activeItem?.kind != .audio, let playingAudio = audioController.currentItem {
                    miniAudioBar(for: playingAudio)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(nil, value: store.selection)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.06))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
            .overlay(alignment: .topTrailing) {
                if let banner = displayManager.lastEventBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "tv.and.hifispeaker.fill")
                            .foregroundStyle(Color.teal)
                        Text(banner)
                            .font(.caption.weight(.medium))
                        Button("Manage") {
                            showDisplayPopover = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.teal.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .help("Toggle Sidebar (⌥⌘S)")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    appThemeMode = (colorScheme == .light) ? "dark" : "light"
                } label: {
                    Image(systemName: colorScheme == .light ? "moon.stars" : "sun.max.fill")
                        .foregroundStyle(colorScheme == .light ? Color.secondary : Color.yellow)
                }
                .help(colorScheme == .light ? "Switch to Dark Theme" : "Switch to Pure White Theme")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showDisplayPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: displayManager.hasExternalDisplay ? "display.2" : "laptopcomputer")
                            .foregroundStyle(displayManager.hasExternalDisplay ? Color.teal : Color.secondary)
                        if displayManager.hasExternalDisplay {
                            Text("HDMI")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.teal)
                        }
                    }
                }
                .help("Displays")
                .popover(isPresented: $showDisplayPopover, arrowEdge: .bottom) {
                    DisplayControlPopover(
                        displayManager: displayManager,
                        activeVideoPlayer: store.activeItem?.kind == .video ? videoController.player : nil
                    )
                }
            }
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            newCollectionDialog
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(items: itemsToShare, session: shareSession) {
                showShareSheet = false
            }
        }
        .sheet(isPresented: $showWelcomeSheet) {
            WelcomeView(
                onAddFolder: {
                    hasSeenWelcome = true
                    showWelcomeSheet = false
                    store.promptAddFolder()
                },
                onContinue: {
                    hasSeenWelcome = true
                    showWelcomeSheet = false
                }
            )
        }
        .onAppear {
            if !hasSeenWelcome {
                showWelcomeSheet = true
            }
            if !hasAskedDefaultPlayer && !DefaultAppManager.isDefaultForMP4() {
                showDefaultBanner = true
            }
        }
        .sheet(item: $store.quickPreviewItem) { item in
            QuickPreviewSheet(item: item) {
                store.quickPreviewItem = nil
                store.openItem(item)
            } onClose: {
                store.quickPreviewItem = nil
            }
        }
    }

    // MARK: - Native Sidebar (Finder / Music / Photos pattern)

    private var sidebar: some View {
        List(selection: $store.selection) {
            Section {
                Label("Dashboard", systemImage: "sparkles.rectangle.stack")
                    .tag(SidebarSelection.dashboard)
            }

            Section("Library") {
                ForEach(SmartCollection.allCases) { smart in
                    HStack(spacing: 8) {
                        Label(smart.rawValue, systemImage: smart.systemImage)
                            .lineLimit(1)
                        Spacer()
                        let c = store.count(for: smart)
                        if c > 0 {
                            Text("\(c)")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    .tag(SidebarSelection.smart(smart))
                }
            }

            Section("Studio") {
                Label("Doc Writer", systemImage: "doc.text.fill")
                    .tag(SidebarSelection.documentStudio)
                Label("Photo Studio", systemImage: "wand.and.stars")
                    .tag(SidebarSelection.photoStudio)
                Label("Video Studio", systemImage: "scissors")
                    .tag(SidebarSelection.videoStudio)
                Label("Wi-Fi Share", systemImage: "qrcode.viewfinder")
                    .tag(SidebarSelection.wifiShare)
            }

            Section {
                if store.folders.isEmpty {
                    Text("No folders added")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .lineLimit(1)
                            .tag(SidebarSelection.folder(folder.id))
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                                }
                                Divider()
                                Button("Remove Folder", role: .destructive) {
                                    store.removeFolder(folder)
                                }
                            }
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Folders", helpText: "Add Media Folder") {
                    store.promptAddFolder()
                }
            }
            .collapsible(false)

            Section {
                if store.collections.isEmpty {
                    Text("No collections")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.collections) { col in
                        HStack {
                            Label(col.name, systemImage: col.symbol)
                                .lineLimit(1)
                            Spacer()
                            if !col.itemIDs.isEmpty {
                                Text("\(col.itemIDs.count)")
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                        }
                        .tag(SidebarSelection.collection(col.id))
                        .contextMenu {
                            Button("Share Collection…") {
                                let ids = Set(col.itemIDs)
                                let list = store.items.filter { ids.contains($0.id) }
                                if !list.isEmpty {
                                    itemsToShare = list
                                    showShareSheet = true
                                }
                            }
                            Divider()
                            Button("Delete Collection", role: .destructive) {
                                store.deleteCollection(col)
                            }
                        }
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Collections", helpText: "New Collection") {
                    newCollectionName = ""
                    showNewCollectionSheet = true
                }
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .font(.system(size: 14, weight: .regular))
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    store.promptAddFolder()
                } label: {
                    Label("Open Folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .onChange(of: store.selection) { _, _ in
            videoController.stop()
            store.activeItem = nil
        }
    }

    // MARK: - Unified Media Explorer

    private var explorerContent: some View {
        VStack(spacing: 0) {
            if showDefaultBanner {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Make ChronoStream your default video player?")
                            .font(.callout.weight(.semibold))
                        Text("Open MP4, MOV, MKV, AVI, and WebM files directly from Finder in ChronoStream.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Not Now") {
                        hasAskedDefaultPlayer = true
                        showDefaultBanner = false
                    }
                    .controlSize(.small)
                    Button("Set as Default") {
                        Task {
                            _ = await DefaultAppManager.setAsDefaultVideoPlayer()
                            hasAskedDefaultPlayer = true
                            showDefaultBanner = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            if store.filteredItems.isEmpty {
                emptyExplorerState
            } else {
                switch store.viewMode {
                case .grid:
                    gridExplorer
                case .list:
                    listExplorer
                }
            }
        }
        .navigationTitle(currentTitle)
        .navigationSubtitle(store.isScanning ? store.scanStatusText : "\(store.filteredItems.count) items")
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Search media…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    let list = store.activeItem.map { [$0] } ?? Array(store.filteredItems.prefix(50))
                    if !list.isEmpty {
                        itemsToShare = list
                        showShareSheet = true
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(store.activeItem == nil && store.filteredItems.isEmpty)
                .help("Share via AirDrop or Wi-Fi QR")

                Button {
                    store.promptOpenFiles()
                } label: {
                    Label("Open", systemImage: "doc.badge.plus")
                }
                .help("Open Files (⌘O)")

                Button {
                    store.promptAddFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Authorize a Media Folder (⇧⌘O)")

                Picker("Sort", selection: $store.sortOrder) {
                    ForEach(MediaSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .help("Sort Order")

                Picker("View", selection: $store.viewMode) {
                    ForEach(ExplorerViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 74)
                .help("Switch Grid / List View")
            }
        }
    }

    private var currentTitle: String {
        switch store.selection {
        case .dashboard: return "Dashboard"
        case .smart(let s): return s.rawValue
        case .folder(let id): return store.folders.first(where: { $0.id == id })?.name ?? "Folder"
        case .collection(let id): return store.collections.first(where: { $0.id == id })?.name ?? "Collection"
        case .photoStudio: return "Photo Studio"
        case .videoStudio: return "Video Studio"
        case .documentStudio: return "Doc Writer"
        case .wifiShare: return "Wi-Fi Share"
        }
    }

    private var emptyExplorerState: some View {
        ContentUnavailableView {
            Label(
                store.folders.isEmpty ? "No Media Folders Added" : "No Matching Media",
                systemImage: store.folders.isEmpty ? "play.square.stack" : "magnifyingglass"
            )
        } description: {
            Text(
                store.folders.isEmpty
                    ? "Add a folder or drag and drop videos, music, photos, or PDFs here. ChronoStream only reads folders you authorize."
                    : "Try a different search query or switch collections in the sidebar."
            )
        } actions: {
            if store.folders.isEmpty {
                Button("Add Media Folder…") { store.promptAddFolder() }
                    .buttonStyle(.borderedProminent)
                Button("Open File…") { store.promptOpenFiles() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridExplorer: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(store.filteredItems) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            LazyThumbnailView(item: item, size: CGSize(width: 196, height: 118))

                            if item.isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(6)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            Text(item.fileExtension)
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }

                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(item.modifiedDate.formatted(date: .abbreviated, time: .omitted))
                            Text("·")
                            Text(MediaFormatting.byteString(item.fileSize))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        if item.lastPosition > 5, item.kind == .video || item.kind == .audio {
                            Text("Resume \(MediaFormatting.timeString(item.lastPosition))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { store.openItem(item) }
                    .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(20)
        }
    }

    private var listExplorer: some View {
        List {
            ForEach(store.filteredItems) { item in
                HStack(spacing: 12) {
                    LazyThumbnailView(item: item, size: CGSize(width: 56, height: 36))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.kind.displayName)
                            Text("·")
                            Text(item.fileExtension)
                            if item.lastPosition > 5 {
                                Text("· Resume \(MediaFormatting.timeString(item.lastPosition))")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(item.modifiedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 145, alignment: .trailing)

                    Text(MediaFormatting.byteString(item.fileSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .trailing)

                    Button {
                        itemsToShare = [item]
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Share via AirDrop or Wi-Fi QR (Android & iPhone)")

                    Button {
                        store.quickPreviewItem = item
                    } label: {
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Preview")

                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(item.isFavorite ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { store.openItem(item) }
                .contextMenu { itemContextMenu(item) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private func itemContextMenu(_ item: MediaItem) -> some View {
        Button("Open") { store.openItem(item) }
        Button("Quick Preview") { store.quickPreviewItem = item }
        Button("Share…") {
            itemsToShare = [item]
            showShareSheet = true
        }
        Button("Share via AirDrop") {
            if let service = NSSharingService(named: .sendViaAirDrop) {
                service.perform(withItems: [item.url])
            } else {
                itemsToShare = [item]
                showShareSheet = true
            }
        }
        Divider()
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(item)
        }
        if !store.collections.isEmpty {
            Menu("Add to Collection") {
                ForEach(store.collections) { col in
                    Button(col.name) { store.addItem(item, to: col.id) }
                }
            }
        }
        if case .collection(let colID) = store.selection {
            Button("Remove from Collection", role: .destructive) {
                store.removeItem(item, from: colID)
            }
        }
        Divider()
        Button("Reveal in Finder") { store.revealInFinder(item) }
    }

    // MARK: - Active Media Viewer Dispatch

    @ViewBuilder
    private func activeViewer(for item: MediaItem) -> some View {
        switch item.kind {
        case .video:
            VideoStageView(
                controller: videoController,
                item: item,
                onShare: {
                    itemsToShare = [item]
                    showShareSheet = true
                },
                onClose: {
                    videoController.stop()
                    store.activeItem = nil
                }
            )
        case .audio:
            AudioStageView(
                controller: audioController,
                item: item,
                queue: store.filteredItems.filter { $0.kind == .audio },
                onSelectTrack: { track in
                    store.openItem(track)
                    audioController.loadTrack(track)
                },
                onShare: {
                    itemsToShare = [item]
                    showShareSheet = true
                },
                onClose: {
                    store.activeItem = nil
                }
            )
        case .image:
            PhotoViewerView(
                item: item,
                siblings: store.filteredItems.filter { $0.kind == .image },
                slideshowInterval: store.slideshowInterval,
                onSelect: { store.openItem($0) },
                onShare: {
                    itemsToShare = [item]
                    showShareSheet = true
                },
                onClose: { store.activeItem = nil }
            )
        case .pdf:
            PDFReaderView(
                item: item,
                onShare: {
                    itemsToShare = [item]
                    showShareSheet = true
                },
                onClose: {
                    store.activeItem = nil
                }
            )
        }
    }

    private func miniAudioBar(for item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(audioController.trackTitle.isEmpty ? item.name : audioController.trackTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(MediaFormatting.timeString(audioController.currentTime)) / \(MediaFormatting.timeString(audioController.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { audioController.playPrevious() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
            Button { audioController.togglePlayPause() } label: {
                Image(systemName: audioController.isPlaying ? "pause.fill" : "play.fill")
            }.buttonStyle(.plain)
            Button { audioController.playNext() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            Button("Expand") { store.openItem(item) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button { audioController.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .padding(14)
    }

    private var newCollectionDialog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Collection")
                .font(.headline)
            Text("Organize videos, music, photos, and PDFs into a virtual group without moving original files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Collection Name (e.g. Lectures, Research)", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewCollection() }
            HStack {
                Spacer()
                Button("Cancel") { showNewCollectionSheet = false }
                Button("Create") { commitNewCollection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commitNewCollection() {
        store.createCollection(name: newCollectionName)
        showNewCollectionSheet = false
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        store.handleDroppedURLs([url], openFirst: true)
                    }
                }
            }
        }
        return handled
    }
}

private struct QuickPreviewSheet: View {
    let item: MediaItem
    let onOpenFull: () -> Void
    let onClose: () -> Void

    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(item.name, systemImage: item.kind.systemImage)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Open Full View", action: onOpenFull)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Close", action: onClose)
                    .controlSize(.small)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                if let img = thumb {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 300)

            HStack {
                Text("Type: \(item.kind.displayName) (\(item.fileExtension))")
                Spacer()
                Text("Size: \(MediaFormatting.byteString(item.fileSize))")
                Spacer()
                Text("Compatibility: \(MediaFormatRegistry.inspectCompatibility(for: item.url).rawValue)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 560)
        .task {
            thumb = await ThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 960)
        }
    }
}
