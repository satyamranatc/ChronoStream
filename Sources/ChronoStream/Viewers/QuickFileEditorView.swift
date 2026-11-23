import AppKit
import SwiftUI
import WebKit

private struct HTMLPreviewWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: baseURL)
    }
}

private struct RichDocDisplayView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.textContainerInset = NSSize(width: 28, height: 24)
            tv.backgroundColor = .textBackgroundColor
            tv.textStorage?.setAttributedString(attributedText)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView {
            tv.textStorage?.setAttributedString(attributedText)
        }
    }
}

/// Clean built-in viewer & basic code/text editor for dropped/opened .txt, .html, code files,
/// Word (.doc/.docx/.rtf), and spreadsheets (.csv/.tsv/.xlsx). No sidebar clutter.
public struct QuickFileEditorView: View {
    let item: MediaItem
    let onShare: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var textContent: String = ""
    @State private var originalContent: String = ""
    @State private var richDoc: NSAttributedString?
    @State private var tableRows: [[String]] = []
    @State private var showPreview: Bool = false
    @State private var fontSize: CGFloat = 13.5
    @State private var statusBanner: String?
    @State private var loadError: String?

    public init(item: MediaItem, onShare: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.item = item
        self.onShare = onShare
        self.onClose = onClose
    }

    private var ext: String { item.url.pathExtension.lowercased() }
    private var isWordDoc: Bool { ["doc", "docx", "rtf", "odt"].contains(ext) }
    private var isXlsx: Bool { ["xlsx", "xls"].contains(ext) }
    private var isCSV: Bool { ["csv", "tsv"].contains(ext) }
    private var isHTML: Bool { ["html", "htm", "svg"].contains(ext) }
    private var isEditableText: Bool { !isWordDoc && !isXlsx }
    private var hasUnsavedChanges: Bool { isEditableText && textContent != originalContent }

    private var lineCount: Int {
        textContent.isEmpty ? 0 : textContent.components(separatedBy: .newlines).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if let err = loadError {
                ContentUnavailableView {
                    Label("Unable to Preview File", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("Open in Default App") {
                        NSWorkspace.shared.open(item.url)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isWordDoc, let richDoc {
                RichDocDisplayView(attributedText: richDoc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (isXlsx || (isCSV && showPreview)), !tableRows.isEmpty {
                spreadsheetTableView
            } else if isHTML && showPreview {
                HTMLPreviewWebView(html: textContent, baseURL: item.url.deletingLastPathComponent())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                codeEditorArea
            }

            Divider()
            statusFooter
        }
        .background(colorScheme == .light ? Color(red: 0.975, green: 0.980, blue: 0.988) : Color(nsColor: .windowBackgroundColor))
        .onAppear { loadFile() }
        .onChange(of: item.id) { _, _ in loadFile() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Back", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)

            HStack(spacing: 6) {
                Image(systemName: iconForExt)
                    .foregroundStyle(Color.accentColor)
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                if hasUnsavedChanges {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
                Text(ext.isEmpty ? "FILE" : ext.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }

            Spacer()

            if isHTML || isCSV {
                Picker("", selection: $showPreview) {
                    Text("Code").tag(false)
                    Text(isHTML ? "Preview" : "Table").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if isEditableText {
                HStack(spacing: 2) {
                    Button { fontSize = max(10, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { fontSize = min(24, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .buttonStyle(.bordered).controlSize(.small)
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(textContent, forType: .string)
                    flashStatus("Copied text to clipboard")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    saveTextFile()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: [.command])
            }

            Button {
                NSWorkspace.shared.open(item.url)
            } label: {
                Label("Open Externally", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Share File")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor))
    }

    private var codeEditorArea: some View {
        TextEditor(text: $textContent)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(14)
            .background(colorScheme == .light ? Color.white : Color(red: 0.09, green: 0.10, blue: 0.12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spreadsheetTableView: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tableRows.prefix(400).enumerated()), id: \.offset) { rIdx, row in
                    HStack(spacing: 0) {
                        Text("\(rIdx + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 42, alignment: .trailing)
                            .padding(.trailing, 8)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.03))

                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(rIdx == 0 ? .caption.weight(.semibold) : .caption)
                                .lineLimit(2)
                                .frame(width: 150, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .overlay(
                                    Rectangle()
                                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                                )
                        }
                    }
                    .background(rIdx == 0 ? Color.accentColor.opacity(0.08) : (rIdx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02)))
                }
            }
            .padding(12)
        }
        .background(colorScheme == .light ? Color.white : Color(nsColor: .textBackgroundColor))
    }

    private var statusFooter: some View {
        HStack(spacing: 14) {
            if let statusBanner {
                Text(statusBanner)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(item.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isEditableText {
                Text("\(lineCount) lines · \(textContent.count) chars")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !tableRows.isEmpty {
                Text("\(tableRows.count) rows")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(MediaFormatting.byteString(item.fileSize))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor))
    }

    private var iconForExt: String {
        if isWordDoc { return "doc.text.fill" }
        if isXlsx || isCSV { return "tablecells" }
        if isHTML { return "globe" }
        return "chevron.left.forwardslash.chevron.right"
    }

    private func flashStatus(_ msg: String) {
        statusBanner = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if statusBanner == msg { statusBanner = nil }
        }
    }

    private func saveTextFile() {
        do {
            try textContent.write(to: item.url, atomically: true, encoding: .utf8)
            originalContent = textContent
            if isCSV {
                tableRows = parseDelimited(textContent, sep: ext == "tsv" ? "\t" : ",")
            }
            flashStatus("Saved \(item.name)")
        } catch {
            flashStatus("Save failed: \(error.localizedDescription)")
        }
    }

    private func loadFile() {
        loadError = nil
        richDoc = nil
        tableRows = []
        showPreview = isCSV

        if isWordDoc {
            let docType: NSAttributedString.DocumentType = {
                switch ext {
                case "docx": return .officeOpenXML
                case "rtf": return .rtf
                case "doc": return .docFormat
                default: return .officeOpenXML
                }
            }()
            if let attr = try? NSAttributedString(url: item.url, options: [.documentType: docType], documentAttributes: nil) {
                richDoc = attr
            } else {
                loadError = "Could not render this Word document natively. Click Open in Default App to view it."
            }
            return
        }

        if isXlsx {
            if ext == "xlsx" {
                let rows = parseXlsx(url: item.url)
                if !rows.isEmpty {
                    tableRows = rows
                } else {
                    loadError = "Could not extract spreadsheet cells from this .xlsx file. Click Open in Default App."
                }
            } else {
                loadError = "Legacy .xls binary spreadsheets open best in Excel or Numbers."
            }
            return
        }

        // Editable code / text / HTML / CSV
        if let raw = try? String(contentsOf: item.url, encoding: .utf8) {
            textContent = raw
            originalContent = raw
            if isCSV {
                tableRows = parseDelimited(raw, sep: ext == "tsv" ? "\t" : ",")
            }
        } else if let raw = try? String(contentsOf: item.url, encoding: .isoLatin1) {
            textContent = raw
            originalContent = raw
        } else {
            loadError = "Binary or unreadable encoding. Click Open in Default App."
        }
    }

    private func parseDelimited(_ text: String, sep: Character) -> [[String]] {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.split(separator: sep, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } }
    }

    private func parseXlsx(url: URL) -> [[String]] {
        func unzipEntry(_ entry: String) -> Data? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-p", url.path, entry]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return p.terminationStatus == 0 ? data : nil
            } catch {
                return nil
            }
        }

        var sharedStrings: [String] = []
        if let ssData = unzipEntry("xl/sharedStrings.xml"),
           let ssDoc = try? XMLDocument(data: ssData),
           let nodes = try? ssDoc.nodes(forXPath: "//*[local-name()='si']") {
            sharedStrings = nodes.map { $0.stringValue ?? "" }
        }

        guard let sheetData = unzipEntry("xl/worksheets/sheet1.xml"),
              let sheetDoc = try? XMLDocument(data: sheetData),
              let rowNodes = try? sheetDoc.nodes(forXPath: "//*[local-name()='row']") else {
            return []
        }

        var result: [[String]] = []
        for rowNode in rowNodes.prefix(400) {
            guard let el = rowNode as? XMLElement else { continue }
            var cells: [String] = []
            for child in el.children ?? [] {
                guard let cellEl = child as? XMLElement, cellEl.localName == "c" else { continue }
                let t = cellEl.attribute(forName: "t")?.stringValue ?? ""
                let v = (try? cellEl.nodes(forXPath: ".//*[local-name()='v' or local-name()='t']").first?.stringValue) ?? ""
                if t == "s", let idx = Int(v), idx >= 0, idx < sharedStrings.count {
                    cells.append(sharedStrings[idx])
                } else {
                    cells.append(v)
                }
            }
            if !cells.isEmpty { result.append(cells) }
        }
        return result
    }
}
