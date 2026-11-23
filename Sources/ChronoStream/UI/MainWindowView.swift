import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LazyThumbnailView: View {
    let item: MediaItem
    let size: CGSize
    var flexibleWidth: Bool = false
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: flexibleWidth ? .infinity : size.width)
            .frame(height: size.height)
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
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isHovered ? Color.white : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(isHovered ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(helpText)
            Spacer()
        }
        .padding(.vertical, 1)
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
    @AppStorage("hasSeenOnboardingV2") private var hasSeenWelcome = false
    @AppStorage("hasAskedDefaultPlayer") private var hasAskedDefaultPlayer = false
    @AppStorage("appThemeMode") private var appThemeMode: String = "light"
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSplash = true
    @State private var showWelcomeSheet = false
    @State private var showConnectFolderPrompt = false
    @State private var showDefaultBanner = false
    @State private var showDisplayPopover = false
    @State private var lastOpenedItemID: String?
    @State private var focusedItemID: String?
    @State private var selectedItemIDs: Set<String> = []
    @State private var isSelectionMode: Bool = false
    @State private var itemToRename: MediaItem?
    @State private var renameText: String = ""
    @State private var explorerWidth: CGFloat = 900
    @State private var explorerKeyMonitor: Any?
    private let displayManager = DisplayManager.shared

    private let gridColumns = [GridItem(.adaptive(minimum: 205, maximum: 250), spacing: 16)]

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
                } else if store.selection == .photoStudio && store.activeItem == nil {
                    PhotoStudioView(store: store)
                } else if store.selection == .videoStudio && store.activeItem == nil {
                    VideoStudioView(store: store)
                } else if store.selection == .documentStudio && store.activeItem == nil {
                    DocumentStudioView()
                } else if store.selection == .wifiShare && store.activeItem == nil {
                    WiFiShareHubView { receivedURL in
                        store.handleDroppedURLs([receivedURL], openFirst: true)
                    }
                } else {
                    // Keep explorerContent alive underneath activeViewer so ScrollView
                    // preserves exact pixel scroll position & thumbnails on return.
                    ZStack {
                        if isExplorerSelection {
                            explorerContent
                                .opacity(store.activeItem == nil ? 1 : 0)
                                .allowsHitTesting(store.activeItem == nil)
                        }

                        if let active = store.activeItem {
                            activeViewer(for: active)
                        }
                    }
                }

                // Persistent mini-player bar when audio is playing while browsing
                if store.activeItem?.kind != .audio, let playingAudio = audioController.currentItem {
                    miniAudioBar(for: playingAudio)
                }

                // Subtle file-operation confirmation toast
                if let toast = store.fileOpMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.teal)
                        Text(toast)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.teal.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: store.activeItem?.id) { _, newID in
                if let newID {
                    lastOpenedItemID = newID
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
        .sheet(item: $itemToRename) { target in
            renameItemDialog(for: target)
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
                    if store.folders.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showConnectFolderPrompt = true
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showConnectFolderPrompt) {
            connectFolderPromptSheet
        }
        .overlay {
            if showSplash {
                SplashScreenView {
                    withAnimation(.easeOut(duration: 0.35)) {
                        showSplash = false
                    }
                    if !hasSeenWelcome {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showWelcomeSheet = true
                        }
                    } else if store.folders.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            showConnectFolderPrompt = true
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(999)
            }
        }
        .onAppear {
            if !hasAskedDefaultPlayer && !DefaultAppManager.isDefaultForMP4() {
                showDefaultBanner = true
            }
            installExplorerKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ChronoStreamReplayWelcome"))) { _ in
            showWelcomeSheet = true
        }
        .onDisappear {
            if let monitor = explorerKeyMonitor {
                NSEvent.removeMonitor(monitor)
                explorerKeyMonitor = nil
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
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleDropIntoFolder(providers: providers, destination: folder.url)
                            }
                            .contextMenu {
                                if store.hasPasteableFiles {
                                    Button("Paste into \(folder.name)") {
                                        store.pasteItems(into: folder.url)
                                    }
                                    Divider()
                                }
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

            if isSelectionMode || selectedItemIDs.count > 1 {
                selectionActionBar
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode { selectedItemIDs.removeAll() }
                    }
                } label: {
                    Label(isSelectionMode ? "Done Selecting" : "Select", systemImage: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help("Select Multiple Items for Cut, Copy, Move, Drag or Trash (or ⌘-Click)")

                if store.hasPasteableFiles {
                    Button {
                        store.pasteItems()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .help(store.clipboardMode == .cut ? "Move Cut Items Here" : "Paste Copied Items Here")
                }

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

    private var isExplorerSelection: Bool {
        switch store.selection {
        case .smart, .folder, .collection:
            return true
        case .dashboard, .photoStudio, .videoStudio, .documentStudio, .wifiShare:
            return false
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

    private var gridColumnCount: Int {
        max(1, Int((explorerWidth - 40 + 16) / (205 + 16)))
    }

    private var gridExplorer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(store.filteredItems) { item in
                        gridCard(for: item, isLastPlayed: item.id == lastOpenedItemID)
                    }
                }
                .padding(20)
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { explorerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in explorerWidth = w }
                }
            )
            .onChange(of: focusedItemID) { _, newID in
                if let newID {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(newID)
                    }
                }
            }
        }
    }

    private func gridCard(for item: MediaItem, isLastPlayed: Bool) -> some View {
        let isSelected = selectedItemIDs.contains(item.id)
        let cardFill: Color = isSelected
            ? Color.accentColor.opacity(0.14)
            : (isLastPlayed ? Color.teal.opacity(0.11) : Color(nsColor: .controlBackgroundColor).opacity(0.65))
        let borderColor: Color = isSelected ? Color.accentColor : (isLastPlayed ? Color.teal : Color.primary.opacity(0.06))
        let borderWidth: CGFloat = (isSelected || isLastPlayed) ? 2 : 1
        let shadowColor: Color = isSelected ? Color.accentColor.opacity(0.2) : (isLastPlayed ? Color.teal.opacity(0.18) : Color.clear)

        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                LazyThumbnailView(item: item, size: CGSize(width: 220, height: 124), flexibleWidth: true)

                HStack(spacing: 4) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    if isSelectionMode || isSelected {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.85))
                            .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.35)))
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if isLastPlayed {
                    Label("Last Played", systemImage: "play.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.teal, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
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
                .font(.callout.weight(isLastPlayed || isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : (isLastPlayed ? Color.teal : .primary))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: shadowColor, radius: 6, y: 2)
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openExplorerItem(item)
        }
        .onTapGesture(count: 1) {
            handleItemTap(item)
        }
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu { itemContextMenu(item) }
    }

    private var listExplorer: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store.filteredItems) { item in
                    listRow(
                        for: item,
                        isLastPlayed: item.id == lastOpenedItemID,
                        isSelected: selectedItemIDs.contains(item.id)
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: focusedItemID) { _, newID in
                if let newID {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        proxy.scrollTo(newID)
                    }
                }
            }
        }
    }

    private func listRow(for item: MediaItem, isLastPlayed: Bool, isSelected: Bool) -> some View {
        let rowBg: Color = isSelected
            ? Color.accentColor.opacity(0.14)
            : (isLastPlayed ? Color.teal.opacity(0.11) : Color.clear)
        let rowStroke: Color = isSelected
            ? Color.accentColor
            : (isLastPlayed ? Color.teal.opacity(0.65) : Color.clear)
        let titleColor: Color = isSelected ? Color.accentColor : (isLastPlayed ? Color.teal : .primary)

        return HStack(spacing: 12) {
            if isSelectionMode || isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            LazyThumbnailView(item: item, size: CGSize(width: 56, height: 36))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.callout.weight(isLastPlayed || isSelected ? .semibold : .medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if isLastPlayed {
                        Text("Last Played")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.teal, in: Capsule())
                    }
                }
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
        .padding(.horizontal, 6)
        .background(rowBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: 1.5)
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openExplorerItem(item)
        }
        .onTapGesture(count: 1) {
            handleItemTap(item)
        }
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu { itemContextMenu(item) }
    }

    private func openExplorerItem(_ item: MediaItem) {
        lastOpenedItemID = item.id
        focusedItemID = item.id
        selectedItemIDs = [item.id]
        store.openItem(item)
    }

    private func handleItemTap(_ item: MediaItem) {
        let flags = NSEvent.modifierFlags
        let cmdHeld = flags.contains(.command)
        let shiftHeld = flags.contains(.shift)

        if shiftHeld, let anchorID = focusedItemID,
           let startIdx = store.filteredItems.firstIndex(where: { $0.id == anchorID }),
           let endIdx = store.filteredItems.firstIndex(where: { $0.id == item.id }) {
            let lo = min(startIdx, endIdx)
            let hi = max(startIdx, endIdx)
            selectedItemIDs = Set(store.filteredItems[lo...hi].map(\.id))
            focusedItemID = item.id
        } else if isSelectionMode || cmdHeld {
            toggleSelection(item)
            focusedItemID = item.id
        } else {
            // Single click selects the item (Finder-style); double-click or Return plays it
            selectedItemIDs = [item.id]
            focusedItemID = item.id
        }
    }

    private func installExplorerKeyMonitor() {
        if let existing = explorerKeyMonitor {
            NSEvent.removeMonitor(existing)
            explorerKeyMonitor = nil
        }
        explorerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard store.activeItem == nil,
                  isExplorerSelection,
                  itemToRename == nil,
                  !showNewCollectionSheet,
                  !showShareSheet,
                  !showWelcomeSheet,
                  store.quickPreviewItem == nil else {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            return handleExplorerKeyDown(event) ? nil : event
        }
    }

    private func handleExplorerKeyDown(_ event: NSEvent) -> Bool {
        let items = store.filteredItems
        guard !items.isEmpty else { return false }

        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if cmd {
            if let ch = event.charactersIgnoringModifiers?.lowercased() {
                switch ch {
                case "a":
                    selectedItemIDs = Set(items.map(\.id))
                    return true
                case "c":
                    if !selectedMediaItems.isEmpty { store.copyItems(selectedMediaItems); return true }
                case "x":
                    if !selectedMediaItems.isEmpty { store.cutItems(selectedMediaItems); return true }
                case "v":
                    if store.hasPasteableFiles { store.pasteItems(); return true }
                default:
                    break
                }
            }
            if event.keyCode == 51, !selectedMediaItems.isEmpty { // ⌘⌫ Move to Trash
                let targets = selectedMediaItems
                store.trashItems(targets)
                selectedItemIDs.removeAll()
                return true
            }
            return false
        }

        let currentID = focusedItemID ?? selectedItemIDs.first ?? lastOpenedItemID
        let currentIdx = currentID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        let stepRow = (store.viewMode == .grid) ? gridColumnCount : 1

        func moveSelection(by delta: Int) {
            let nextIdx: Int
            if let idx = currentIdx {
                nextIdx = max(0, min(items.count - 1, idx + delta))
            } else {
                nextIdx = 0
            }
            let target = items[nextIdx]
            focusedItemID = target.id
            if shift {
                selectedItemIDs.insert(target.id)
            } else {
                selectedItemIDs = [target.id]
            }
        }

        switch event.keyCode {
        case 123: // Left arrow
            moveSelection(by: -1)
            return true
        case 124: // Right arrow
            moveSelection(by: 1)
            return true
        case 126: // Up arrow
            moveSelection(by: -stepRow)
            return true
        case 125: // Down arrow
            moveSelection(by: stepRow)
            return true
        case 36, 76: // Return / Enter — play selected item
            if let idx = currentIdx {
                openExplorerItem(items[idx])
                return true
            }
            return false
        case 49: // Space — Quick Preview
            if let idx = currentIdx {
                store.quickPreviewItem = items[idx]
                return true
            }
            return false
        case 53: // Escape — clear selection
            if !selectedItemIDs.isEmpty || isSelectionMode {
                selectedItemIDs.removeAll()
                isSelectionMode = false
                return true
            }
            return false
        default:
            return false
        }
    }

    private func toggleSelection(_ item: MediaItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func actionTargets(for item: MediaItem) -> [MediaItem] {
        if selectedItemIDs.contains(item.id) && selectedItemIDs.count > 1 {
            return store.filteredItems.filter { selectedItemIDs.contains($0.id) }
        }
        return [item]
    }

    private var selectedMediaItems: [MediaItem] {
        store.filteredItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Text(selectedItemIDs.isEmpty ? "Click items or ⌘-Click to select" : "\(selectedItemIDs.count) selected")
                .font(.callout.weight(.semibold))
                .foregroundStyle(selectedItemIDs.isEmpty ? .secondary : .primary)

            Button("Select All") {
                selectedItemIDs = Set(store.filteredItems.map(\.id))
            }
            .controlSize(.small)

            if !selectedItemIDs.isEmpty {
                Button("Clear") { selectedItemIDs.removeAll() }
                    .controlSize(.small)
            }

            Spacer()

            Group {
                Button {
                    store.cutItems(selectedMediaItems)
                } label: {
                    Label("Cut", systemImage: "scissors")
                }

                Button {
                    store.copyItems(selectedMediaItems)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                if store.hasPasteableFiles {
                    Button {
                        store.pasteItems()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                }

                Button {
                    store.promptMoveItems(selectedMediaItems)
                    selectedItemIDs.removeAll()
                } label: {
                    Label("Move…", systemImage: "folder")
                }

                Button {
                    itemsToShare = selectedMediaItems
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    store.trashItems(selectedMediaItems)
                    selectedItemIDs.removeAll()
                } label: {
                    Label("Trash", systemImage: "trash")
                }
            }
            .controlSize(.small)
            .disabled(selectedItemIDs.isEmpty)

            Button("Done") {
                isSelectionMode = false
                selectedItemIDs.removeAll()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.07))
    }

    @ViewBuilder
    private func itemContextMenu(_ item: MediaItem) -> some View {
        let targets = actionTargets(for: item)
        let suffix = targets.count > 1 ? " (\(targets.count))" : ""
        let isSelected = selectedItemIDs.contains(item.id)

        Button {
            lastOpenedItemID = item.id
            store.openItem(item)
        } label: {
            Label("Open", systemImage: "play.fill")
        }

        Button {
            store.quickPreviewItem = item
        } label: {
            Label("Quick Preview", systemImage: "eye")
        }

        Button {
            toggleSelection(item)
        } label: {
            Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle")
        }

        Button {
            selectedItemIDs = Set(store.filteredItems.map(\.id))
            isSelectionMode = true
        } label: {
            Label("Select All", systemImage: "checkmark.rectangle.stack")
        }

        Divider()

        Button {
            store.cutItems(targets)
        } label: {
            Label("Cut\(suffix)", systemImage: "scissors")
        }

        Button {
            store.copyItems(targets)
        } label: {
            Label("Copy\(suffix)", systemImage: "doc.on.doc")
        }

        if store.hasPasteableFiles {
            Button {
                store.pasteItems(into: item.url.deletingLastPathComponent())
            } label: {
                Label("Paste into This Folder", systemImage: "doc.on.clipboard")
            }
        }

        Button {
            store.duplicateItems(targets)
        } label: {
            Label("Duplicate\(suffix)", systemImage: "plus.square.on.square")
        }

        if targets.count == 1 {
            Button {
                renameText = item.name
                itemToRename = item
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }

        Button {
            store.promptMoveItems(targets)
            selectedItemIDs.subtract(targets.map(\.id))
        } label: {
            Label("Move to Folder…\(suffix)", systemImage: "folder")
        }

        Divider()

        Button {
            itemsToShare = targets
            showShareSheet = true
        } label: {
            Label("Share…\(suffix)", systemImage: "square.and.arrow.up")
        }

        Button {
            if let service = NSSharingService(named: .sendViaAirDrop) {
                service.perform(withItems: targets.map(\.url))
            } else {
                itemsToShare = targets
                showShareSheet = true
            }
        } label: {
            Label("Share via AirDrop\(suffix)", systemImage: "airplayaudio")
        }

        Button {
            for t in targets { store.toggleFavorite(t) }
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "heart.slash" : "heart")
        }

        if !store.collections.isEmpty {
            Menu("Add to Collection") {
                ForEach(store.collections) { col in
                    Button(col.name) {
                        for t in targets { store.addItem(t, to: col.id) }
                    }
                }
            }
        }

        if case .collection(let colID) = store.selection {
            Button("Remove from Collection", role: .destructive) {
                for t in targets { store.removeItem(t, from: colID) }
            }
        }

        Divider()

        Button {
            store.copyPaths(targets)
        } label: {
            Label("Copy Path\(suffix)", systemImage: "link")
        }

        Button {
            store.revealInFinder(item)
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
        }

        Divider()

        Button(role: .destructive) {
            store.trashItems(targets)
            selectedItemIDs.subtract(targets.map(\.id))
        } label: {
            Label("Move to Trash\(suffix)", systemImage: "trash")
        }
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

    private var connectFolderPromptSheet: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 60, height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                    )
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 4)

            VStack(spacing: 6) {
                Text("Connect a Media Folder")
                    .font(.title3.weight(.bold))

                Text("Hey! Connect any folder with your videos, music, photos, or PDFs so ChronoStream can show your library right away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Not Now") {
                    showConnectFolderPrompt = false
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    showConnectFolderPrompt = false
                    store.promptAddFolder()
                } label: {
                    Label("Connect Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 420)
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

    private func renameItemDialog(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename File")
                .font(.headline)
            Text("Enter a new filename. The file extension will be preserved automatically if omitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filename", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if store.renameItem(item, to: renameText) {
                        itemToRename = nil
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { itemToRename = nil }
                Button("Rename") {
                    if store.renameItem(item, to: renameText) {
                        itemToRename = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func handleDropIntoFolder(providers: [NSItemProvider], destination: URL) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let existing = store.items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                            store.moveItems([existing], to: destination)
                        } else {
                            let temp = MediaItem(url: url, kind: MediaFormatRegistry.kind(for: url) ?? .video, fileSize: 0, modifiedDate: Date())
                            store.moveItems([temp], to: destination)
                        }
                    }
                }
            }
        }
        return handled
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
