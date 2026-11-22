import AppKit
import Foundation
import Observation
import PDFKit
import SwiftUI

// MARK: - Reading Theme & Layout Enums

public enum BookReadingTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case original = "Paper"
    case sepia = "Sepia"
    case eink = "Soft Gray"
    case night = "Night"

    public var id: String { rawValue }

    public var swatchColor: Color {
        switch self {
        case .original: return .white
        case .sepia: return Color(red: 0.96, green: 0.92, blue: 0.83)
        case .eink: return Color(red: 0.89, green: 0.90, blue: 0.91)
        case .night: return Color(red: 0.12, green: 0.13, blue: 0.15)
        }
    }
}

public enum BookLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case continuous = "Scroll"
    case singlePage = "Single"
    case twoUp = "Book Spread"

    public var id: String { rawValue }

    public var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .continuous: return .singlePageContinuous
        case .singlePage: return .singlePage
        case .twoUp: return .twoUpContinuous
        }
    }

    public var systemImage: String {
        switch self {
        case .continuous: return "scroll"
        case .singlePage: return "doc"
        case .twoUp: return "book.pages"
        }
    }
}

private enum ReaderSidebarTab: String, CaseIterable, Identifiable {
    case chapters = "Chapters"
    case bookmarks = "Bookmarks"
    case notes = "Notes"
    var id: String { rawValue }
}

// MARK: - Persistent Per-Book Reading State (Last Page, Bookmarks, Notes)

public struct BookNote: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let pageIndex: Int
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), pageIndex: Int, text: String, createdAt: Date = Date()) {
        self.id = id
        self.pageIndex = pageIndex
        self.text = text
        self.createdAt = createdAt
    }
}

public struct BookReadingProgress: Codable, Hashable, Sendable {
    public var lastPageIndex: Int = 0
    public var bookmarks: [Int] = []
    public var notes: [BookNote] = []
}

@MainActor
@Observable
public final class BookReaderStore {
    public static let shared = BookReaderStore()

    public var books: [String: BookReadingProgress] = [:]

    private static let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ChronoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pdf_reader_state.json")
    }()

    private init() { load() }

    public func progress(for path: String) -> BookReadingProgress {
        books[path] ?? BookReadingProgress()
    }

    public func updateLastPage(for path: String, pageIndex: Int) {
        var p = progress(for: path)
        guard p.lastPageIndex != pageIndex else { return }
        p.lastPageIndex = pageIndex
        books[path] = p
        save()
    }

    public func toggleBookmark(for path: String, pageIndex: Int) {
        var p = progress(for: path)
        if let idx = p.bookmarks.firstIndex(of: pageIndex) {
            p.bookmarks.remove(at: idx)
        } else {
            p.bookmarks.append(pageIndex)
            p.bookmarks.sort()
        }
        books[path] = p
        save()
    }

    public func isBookmarked(for path: String, pageIndex: Int) -> Bool {
        progress(for: path).bookmarks.contains(pageIndex)
    }

    public func addNote(for path: String, pageIndex: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var p = progress(for: path)
        p.notes.insert(BookNote(pageIndex: pageIndex, text: trimmed), at: 0)
        books[path] = p
        save()
    }

    public func deleteNote(for path: String, noteID: UUID) {
        var p = progress(for: path)
        p.notes.removeAll { $0.id == noteID }
        books[path] = p
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode([String: BookReadingProgress].self, from: data) else { return }
        books = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }
}

private struct PDFChapterEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let depth: Int
}

// MARK: - Native PDFKit Representable

private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var currentPageIndex: Int
    let scaleFactor: CGFloat?
    let layoutMode: BookLayoutMode
    let readingTheme: BookReadingTheme
    let activeSelection: PDFSelection?

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageIndex: $currentPageIndex)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = layoutMode.pdfDisplayMode
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        pdfView.backgroundColor = backgroundNSColor(for: readingTheme)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
            pdfView.autoScales = true
        }
        if pdfView.displayMode != layoutMode.pdfDisplayMode {
            pdfView.displayMode = layoutMode.pdfDisplayMode
        }
        pdfView.backgroundColor = backgroundNSColor(for: readingTheme)

        if let scale = scaleFactor {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
        } else if !pdfView.autoScales {
            pdfView.autoScales = true
        }

        if let doc = document, currentPageIndex >= 0, currentPageIndex < doc.pageCount,
           let targetPage = doc.page(at: currentPageIndex),
           pdfView.currentPage !== targetPage {
            pdfView.go(to: targetPage)
        }
        if let sel = activeSelection {
            pdfView.setCurrentSelection(sel, animate: true)
            pdfView.go(to: sel)
        }
    }

    private func backgroundNSColor(for theme: BookReadingTheme) -> NSColor {
        switch theme {
        case .original: return NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
        case .sepia: return NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.78, alpha: 1)
        case .eink: return NSColor(calibratedRed: 0.85, green: 0.86, blue: 0.88, alpha: 1)
        case .night: return NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        }
    }

    final class Coordinator: NSObject {
        var currentPageIndex: Binding<Int>
        init(currentPageIndex: Binding<Int>) { self.currentPageIndex = currentPageIndex }

        @MainActor
        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let idx = doc.index(for: page)
            if idx != NSNotFound && idx != currentPageIndex.wrappedValue {
                currentPageIndex.wrappedValue = idx
            }
        }
    }
}

// MARK: - Best-in-Segment Book & PDF Reader View

public struct PDFReaderView: View {
    let item: MediaItem
    let onShare: () -> Void
    let onClose: () -> Void

    @State private var document: PDFDocument?
    @State private var chapters: [PDFChapterEntry] = []
    @State private var currentPageIndex: Int = 0
    @State private var scaleFactor: CGFloat? = nil
    @State private var layoutMode: BookLayoutMode = .continuous
    @AppStorage("pdfReadingTheme") private var readingThemeRaw: String = BookReadingTheme.original.rawValue
    @State private var showSidebar: Bool = true
    @State private var sidebarTab: ReaderSidebarTab = .chapters
    @State private var zenFocusMode: Bool = false

    @State private var searchQuery: String = ""
    @State private var searchMatches: [PDFSelection] = []
    @State private var matchIndex: Int = 0
    @State private var newNoteText: String = ""
    @State private var jumpPageInput: String = ""
    @State private var loadError: String?

    private let readerStore = BookReaderStore.shared

    public init(item: MediaItem, onShare: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.item = item
        self.onShare = onShare
        self.onClose = onClose
    }

    private var readingTheme: BookReadingTheme {
        BookReadingTheme(rawValue: readingThemeRaw) ?? .original
    }

    private var pageCount: Int { document?.pageCount ?? 0 }

    private var progressFraction: Double {
        guard pageCount > 1 else { return pageCount == 1 ? 1.0 : 0.0 }
        return Double(currentPageIndex) / Double(pageCount - 1)
    }

    private var estimatedMinutesLeft: Int {
        let remainingPages = max(0, pageCount - (currentPageIndex + 1))
        return max(1, Int(ceil(Double(remainingPages) * 1.4))) // ~1.4 min per book page
    }

    private var bookProgress: BookReadingProgress {
        readerStore.progress(for: item.path)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !zenFocusMode {
                topBookToolbar
                Divider()
            }

            HStack(spacing: 0) {
                if showSidebar && !zenFocusMode {
                    readerSidebar
                        .frame(width: 248)
                    Divider()
                }

                // Book Stage with Eye-Friendly Theme Tint & Focus Overlay
                ZStack(alignment: .topTrailing) {
                    if let err = loadError {
                        ContentUnavailableView("Cannot Open Book / PDF", systemImage: "doc.badge.ellipsis", description: Text(err))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PDFKitRepresentable(
                            document: document,
                            currentPageIndex: $currentPageIndex,
                            scaleFactor: scaleFactor,
                            layoutMode: layoutMode,
                            readingTheme: readingTheme,
                            activeSelection: searchMatches.indices.contains(matchIndex) ? searchMatches[matchIndex] : nil
                        )
                        .colorInvertIf(readingTheme == .night)
                        .overlay {
                            if readingTheme == .sepia {
                                Color(red: 0.96, green: 0.87, blue: 0.68)
                                    .opacity(0.22)
                                    .blendMode(.multiply)
                                    .allowsHitTesting(false)
                            } else if readingTheme == .eink {
                                Color.black
                                    .opacity(0.06)
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    if zenFocusMode {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { zenFocusMode = false }
                        } label: {
                            Label("Exit Focus", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .controlSize(.small)
                        .padding(14)
                    }
                }
            }

            if !zenFocusMode && pageCount > 0 {
                Divider()
                bottomReadingBar
            }
        }
        .onAppear { loadPDF() }
        .onChange(of: item.id) { _, _ in loadPDF() }
        .onChange(of: currentPageIndex) { _, newPage in
            readerStore.updateLastPage(for: item.path, pageIndex: newPage)
        }
        .onChange(of: searchQuery) { _, newVal in
            if newVal.trimmingCharacters(in: .whitespaces).isEmpty {
                searchMatches = []
                matchIndex = 0
            }
        }
    }

    // MARK: - Top Book Toolbar

    private var topBookToolbar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle Chapters, Bookmarks & Notes")

            Text(item.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer()

            // Layout Mode (Scroll / Single / Book Spread)
            Picker("", selection: $layoutMode) {
                ForEach(BookLayoutMode.allCases) { mode in
                    Image(systemName: mode.systemImage)
                        .help(mode.rawValue)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
            .controlSize(.small)

            // Eye-Friendly Reading Theme Swatches
            Menu {
                ForEach(BookReadingTheme.allCases) { theme in
                    Button {
                        readingThemeRaw = theme.rawValue
                    } label: {
                        HStack {
                            Text(theme.rawValue)
                            if readingTheme == theme { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(readingTheme.swatchColor)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                    Text(readingTheme.rawValue)
                        .font(.caption.weight(.medium))
                }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
            .help("Reading Paper Theme")

            // Zoom
            HStack(spacing: 3) {
                Button { scaleFactor = max(0.5, (scaleFactor ?? 1.0) - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                Button("Fit") { scaleFactor = nil }
                Button { scaleFactor = min(4.0, (scaleFactor ?? 1.0) + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Bookmark Current Page
            let bookmarked = readerStore.isBookmarked(for: item.path, pageIndex: currentPageIndex)
            Button {
                readerStore.toggleBookmark(for: item.path, pageIndex: currentPageIndex)
            } label: {
                Image(systemName: bookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(bookmarked ? Color.teal : Color.primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(bookmarked ? "Remove Bookmark" : "Bookmark Page \(currentPageIndex + 1)")

            // Search
            HStack(spacing: 4) {
                TextField("Search book…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)
                    .controlSize(.small)
                    .onSubmit { runSearch() }

                if !searchMatches.isEmpty {
                    Text("\(matchIndex + 1)/\(searchMatches.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { stepMatch(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { stepMatch(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { zenFocusMode = true }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Zen Reading Focus Mode")

            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Share via AirDrop or Wi-Fi QR")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Reader Sidebar (Chapters, Bookmarks, Notes)

    private var readerSidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                ForEach(ReaderSidebarTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(10)

            Divider()

            switch sidebarTab {
            case .chapters:
                if chapters.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "book.closed")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No table of contents")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Use Bookmarks or the bottom progress bar to jump to any page.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                        Spacer()
                    }
                } else {
                    List(chapters) { ch in
                        Button {
                            currentPageIndex = ch.pageIndex
                        } label: {
                            HStack {
                                Text(ch.title)
                                    .font(.caption.weight(ch.depth == 0 ? .semibold : .regular))
                                    .lineLimit(2)
                                    .padding(.leading, CGFloat(min(ch.depth, 3) * 10))
                                Spacer()
                                Text("\(ch.pageIndex + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }

            case .bookmarks:
                if bookProgress.bookmarks.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "bookmark")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No bookmarks yet")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button("Bookmark Page \(currentPageIndex + 1)") {
                            readerStore.toggleBookmark(for: item.path, pageIndex: currentPageIndex)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                } else {
                    List(bookProgress.bookmarks, id: \.self) { pageIdx in
                        HStack {
                            Button {
                                currentPageIndex = pageIdx
                            } label: {
                                Label("Page \(pageIdx + 1)", systemImage: "bookmark.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(pageIdx == currentPageIndex ? Color.teal : Color.primary)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                readerStore.toggleBookmark(for: item.path, pageIndex: pageIdx)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.inset)
                }

            case .notes:
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        TextField("Add note for Page \(currentPageIndex + 1)…", text: $newNoteText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                            .font(.caption)
                        Button {
                            readerStore.addNote(for: item.path, pageIndex: currentPageIndex, text: newNoteText)
                            newNoteText = ""
                        } label: {
                            Label("Save Note on Page \(currentPageIndex + 1)", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .controlSize(.small)
                        .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(10)

                    Divider()

                    if bookProgress.notes.isEmpty {
                        VStack(spacing: 6) {
                            Spacer()
                            Text("No reading notes yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                    } else {
                        List(bookProgress.notes) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Button("Page \(note.pageIndex + 1)") {
                                        currentPageIndex = note.pageIndex
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption2.weight(.bold))
                                    Spacer()
                                    Button {
                                        readerStore.deleteNote(for: item.path, noteID: note.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(note.text)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Bottom Book Reading Progress Bar

    private var bottomReadingBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { if currentPageIndex > 0 { currentPageIndex -= 1 } } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPageIndex <= 0)
                Button { if currentPageIndex + 1 < pageCount { currentPageIndex += 1 } } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPageIndex + 1 >= pageCount)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Page \(currentPageIndex + 1) of \(pageCount)")
                .font(.caption.monospacedDigit().weight(.medium))

            Slider(
                value: Binding(
                    get: { Double(currentPageIndex) },
                    set: { currentPageIndex = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, pageCount - 1))
            )
            .tint(.teal)

            Text("\(Int((progressFraction * 100).rounded()))% · ~\(estimatedMinutesLeft)m left")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                TextField("Go", text: $jumpPageInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .controlSize(.small)
                    .onSubmit {
                        if let p = Int(jumpPageInput.trimmingCharacters(in: .whitespaces)), p >= 1, p <= pageCount {
                            currentPageIndex = p - 1
                        }
                        jumpPageInput = ""
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func loadPDF() {
        loadError = nil
        searchQuery = ""
        searchMatches = []
        chapters = []

        guard MediaFormatRegistry.inspectCompatibility(for: item.url) == .nativePDFKit,
              let doc = PDFDocument(url: item.url) else {
            document = nil
            loadError = "This PDF file appears invalid or corrupted."
            return
        }
        document = doc

        // Restore last-read page automatically
        let saved = readerStore.progress(for: item.path).lastPageIndex
        currentPageIndex = max(0, min(max(0, doc.pageCount - 1), saved))

        // Extract Table of Contents (PDFOutline)
        if let root = doc.outlineRoot {
            var collected: [PDFChapterEntry] = []
            collectOutline(root, in: doc, depth: 0, into: &collected)
            chapters = collected
        }
    }

    private func collectOutline(_ outline: PDFOutline, in doc: PDFDocument, depth: Int, into list: inout [PDFChapterEntry]) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
               let destPage = child.destination?.page {
                let idx = doc.index(for: destPage)
                if idx != NSNotFound {
                    list.append(PDFChapterEntry(title: label, pageIndex: idx, depth: depth))
                }
            }
            if child.numberOfChildren > 0 && depth < 3 {
                collectOutline(child, in: doc, depth: depth + 1, into: &list)
            }
        }
    }

    private func runSearch() {
        guard let doc = document else { return }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchMatches = []; return }
        searchMatches = doc.findString(q, withOptions: [.caseInsensitive])
        matchIndex = 0
    }

    private func stepMatch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        matchIndex = (matchIndex + delta + searchMatches.count) % searchMatches.count
    }
}

private extension View {
    @ViewBuilder
    func colorInvertIf(_ condition: Bool) -> some View {
        if condition {
            self.colorInvert()
        } else {
            self
        }
    }
}
