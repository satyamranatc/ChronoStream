import AppKit
import PDFKit
import SwiftUI

private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var currentPageIndex: Int
    let scaleFactor: CGFloat?
    let activeSelection: PDFSelection?

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageIndex: $currentPageIndex)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
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

public struct PDFReaderView: View {
    let item: MediaItem
    let onShare: () -> Void
    let onClose: () -> Void

    @State private var document: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var scaleFactor: CGFloat? = nil // nil = Auto Fit
    @State private var searchQuery: String = ""
    @State private var searchMatches: [PDFSelection] = []
    @State private var matchIndex: Int = 0
    @State private var loadError: String?

    public init(item: MediaItem, onShare: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.item = item
        self.onShare = onShare
        self.onClose = onClose
    }

    private var pageCount: Int { document?.pageCount ?? 0 }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                // Page navigation
                HStack(spacing: 4) {
                    Button {
                        if currentPageIndex > 0 { currentPageIndex -= 1 }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(currentPageIndex <= 0)

                    Text("Page \(pageCount > 0 ? currentPageIndex + 1 : 0) of \(pageCount)")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 82)

                    Button {
                        if currentPageIndex + 1 < pageCount { currentPageIndex += 1 }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(currentPageIndex + 1 >= pageCount)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider().frame(height: 16)

                // Zoom
                HStack(spacing: 4) {
                    Button {
                        scaleFactor = max(0.5, (scaleFactor ?? 1.0) - 0.2)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Button("Fit") { scaleFactor = nil }
                    Button {
                        scaleFactor = min(4.0, (scaleFactor ?? 1.0) + 0.2)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider().frame(height: 16)

                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Share via AirDrop or Wi-Fi QR (Android & iPhone)")

                Divider().frame(height: 16)

                // In-document search
                HStack(spacing: 4) {
                    TextField("Search PDF…", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if let err = loadError {
                ContentUnavailableView("Cannot Open PDF", systemImage: "doc.badge.ellipsis", description: Text(err))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PDFKitRepresentable(
                    document: document,
                    currentPageIndex: $currentPageIndex,
                    scaleFactor: scaleFactor,
                    activeSelection: searchMatches.indices.contains(matchIndex) ? searchMatches[matchIndex] : nil
                )
            }
        }
        .onAppear { loadPDF() }
        .onChange(of: item.id) { _, _ in loadPDF() }
        .onChange(of: searchQuery) { _, newVal in
            if newVal.trimmingCharacters(in: .whitespaces).isEmpty {
                searchMatches = []
                matchIndex = 0
            }
        }
    }

    private func loadPDF() {
        loadError = nil
        currentPageIndex = 0
        searchQuery = ""
        searchMatches = []
        guard MediaFormatRegistry.inspectCompatibility(for: item.url) == .nativePDFKit,
              let doc = PDFDocument(url: item.url) else {
            document = nil
            loadError = "This PDF file appears invalid or corrupted."
            return
        }
        document = doc
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
