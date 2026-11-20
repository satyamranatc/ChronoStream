import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

public struct SavedDocEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let ext: String
    public let modifiedAt: Date
    public let fileSize: Int64

    public init(url: URL) {
        self.id = url.path
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.ext = url.pathExtension.uppercased()
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.modifiedAt = vals?.contentModificationDate ?? Date()
        self.fileSize = Int64(vals?.fileSize ?? 0)
    }
}

@MainActor
@Observable
public final class DocumentEditorController {
    public weak var textView: NSTextView?
    public var documentTitle: String = "Untitled Document"
    public var currentFileURL: URL?
    public var isDirty: Bool = false
    public var wordCount: Int = 0
    public var charCount: Int = 0
    public var pageCount: Int = 1

    // Live cursor formatting state
    public var fontFamily: String = "System"
    public var fontSize: CGFloat = 15
    public var isBold: Bool = false
    public var isItalic: Bool = false
    public var isUnderline: Bool = false
    public var isStrikethrough: Bool = false
    public var alignment: NSTextAlignment = .left
    public var lineSpacingMultiple: CGFloat = 1.25

    public var pageZoom: CGFloat = 1.0
    public var teachingFocusMode: Bool = false
    public var showDocsSidebar: Bool = true
    public var statusMessage: String?
    public var savedDocuments: [SavedDocEntry] = []

    public static let defaultDocsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let dir = docs.appendingPathComponent("ChronoStream Docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let docxType: UTType = UTType(filenameExtension: "docx") ?? .data

    public init() {
        refreshSavedDocuments()
    }

    public func refreshSavedDocuments() {
        let fm = FileManager.default
        let dir = Self.defaultDocsDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let allowedExts: Set<String> = ["docx", "doc", "rtf", "rtfd", "html", "txt"]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            savedDocuments = []
            return
        }
        savedDocuments = urls
            .filter { allowedExts.contains($0.pathExtension.lowercased()) }
            .map(SavedDocEntry.init(url:))
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func updateStats() {
        guard let text = textView?.string else { return }
        charCount = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }
        wordCount = words.count
        pageCount = max(1, Int(ceil(Double(max(1, wordCount)) / 320.0)))
    }

    public func syncFormattingFromSelection() {
        guard let tv = textView else { return }
        let attrs: [NSAttributedString.Key: Any]
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else if let storage = tv.textStorage, storage.length > 0, range.location > 0 {
            attrs = storage.attributes(at: min(range.location - 1, storage.length - 1), effectiveRange: nil)
        } else {
            attrs = tv.typingAttributes
        }

        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            isBold = traits.contains(.boldFontMask)
            isItalic = traits.contains(.italicFontMask)
            fontSize = font.pointSize
            let fam = (font.familyName ?? "").lowercased()
            if fam.contains("georgia") { fontFamily = "Georgia" }
            else if fam.contains("times") { fontFamily = "Times New Roman" }
            else if fam.contains("helvetica") { fontFamily = "Helvetica Neue" }
            else if fam.contains("menlo") || fam.contains("mono") { fontFamily = "Mono" }
            else { fontFamily = "System" }
        }
        isUnderline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        isStrikethrough = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
            alignment = para.alignment
        }
    }

    // MARK: - Undo / Redo / Find

    public func undo() { textView?.undoManager?.undo() }
    public func redo() { textView?.undoManager?.redo() }

    public func openFindBar() {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performFindPanelAction(item)
    }

    // MARK: - Rich-Text Formatting Actions

    public func toggleBold() {
        applyFontTrait(.boldFontMask)
        syncFormattingFromSelection()
    }

    public func toggleItalic() {
        applyFontTrait(.italicFontMask)
        syncFormattingFromSelection()
    }

    public func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let cur = (attrs[.underlineStyle] as? Int) ?? 0
            attrs[.underlineStyle] = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            syncFormattingFromSelection()
            return
        }
        let existing = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int) ?? 0
        let next = existing == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.addAttribute(.underlineStyle, value: next, range: range)
        isDirty = true
        syncFormattingFromSelection()
    }

    public func toggleStrikethrough() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let cur = (attrs[.strikethroughStyle] as? Int) ?? 0
            attrs[.strikethroughStyle] = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            syncFormattingFromSelection()
            return
        }
        let existing = (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int) ?? 0
        let next = existing == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.addAttribute(.strikethroughStyle, value: next, range: range)
        isDirty = true
        syncFormattingFromSelection()
    }

    public func applyTextStyle(_ style: String) {
        guard let tv = textView else { return }
        let font: NSFont
        let color: NSColor
        var bg: NSColor? = nil
        switch style {
        case "Title":
            font = NSFont.systemFont(ofSize: 28, weight: .bold)
            color = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.14, alpha: 1)
        case "Heading 1":
            font = NSFont.systemFont(ofSize: 21, weight: .bold)
            color = NSColor(calibratedRed: 0.0, green: 0.42, blue: 0.44, alpha: 1)
        case "Heading 2":
            font = NSFont.systemFont(ofSize: 17, weight: .semibold)
            color = NSColor(calibratedRed: 0.14, green: 0.2, blue: 0.24, alpha: 1)
        case "Heading 3":
            font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            color = NSColor(calibratedRed: 0.25, green: 0.32, blue: 0.36, alpha: 1)
        case "Quote":
            font = NSFont(name: "Georgia-Italic", size: 15.5) ?? NSFont.systemFont(ofSize: 15.5)
            color = NSColor(calibratedRed: 0.28, green: 0.34, blue: 0.38, alpha: 1)
        case "Code":
            font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
            color = NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.34, alpha: 1)
            bg = NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.97, alpha: 1)
        default:
            font = resolvedFont(family: fontFamily, size: 15)
            color = NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)
        }

        let range = tv.selectedRange()
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let bg { attrs[.backgroundColor] = bg }
        if range.length > 0, let storage = tv.textStorage {
            storage.addAttributes(attrs, range: range)
            if bg == nil { storage.removeAttribute(.backgroundColor, range: range) }
            isDirty = true
        } else {
            var typing = tv.typingAttributes
            typing[.font] = font
            typing[.foregroundColor] = color
            if let bg { typing[.backgroundColor] = bg } else { typing.removeValue(forKey: .backgroundColor) }
            tv.typingAttributes = typing
        }
        syncFormattingFromSelection()
    }

    public func applyFont(family: String, size: CGFloat) {
        self.fontFamily = family
        self.fontSize = size
        guard let tv = textView else { return }
        let font = resolvedFont(family: family, size: size)
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage {
            storage.addAttribute(.font, value: font, range: range)
            isDirty = true
        } else {
            tv.typingAttributes[.font] = font
        }
    }

    public func applyHighlight(_ color: NSColor?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage {
            if let c = color {
                storage.addAttribute(.backgroundColor, value: c, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            isDirty = true
        } else {
            if let c = color {
                tv.typingAttributes[.backgroundColor] = c
            } else {
                tv.typingAttributes.removeValue(forKey: .backgroundColor)
            }
        }
    }

    public func applyTextColor(_ color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage {
            storage.addAttribute(.foregroundColor, value: color, range: range)
            isDirty = true
        } else {
            tv.typingAttributes[.foregroundColor] = color
        }
    }

    public func setAlignment(_ newAlignment: NSTextAlignment) {
        guard let tv = textView else { return }
        tv.setAlignment(newAlignment, range: tv.selectedRange())
        alignment = newAlignment
        isDirty = true
    }

    public func setLineSpacing(_ multiple: CGFloat) {
        lineSpacingMultiple = multiple
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = multiple
        para.paragraphSpacing = 6
        para.alignment = alignment
        if range.length > 0 {
            storage.addAttribute(.paragraphStyle, value: para, range: range)
            isDirty = true
        } else {
            tv.typingAttributes[.paragraphStyle] = para
        }
    }

    public func insertBulletList() {
        insertSnippet("\n• Point 1\n• Point 2\n• Point 3\n")
    }

    public func insertNumberedList() {
        insertSnippet("\n1. Step one\n2. Step two\n3. Step three\n")
    }

    public func insertHorizontalRule() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let line = NSAttributedString(
            string: "\n────────────────────────────────────────────────────────────\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.separatorColor
            ]
        )
        let pos = tv.selectedRange().location
        storage.insert(line, at: pos)
        tv.setSelectedRange(NSRange(location: pos + line.length, length: 0))
        isDirty = true
        updateStats()
    }

    public func insertTable(rows: Int = 3, cols: Int = 3) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let result = NSMutableAttributedString(string: "\n")
        for r in 0..<rows {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(1.0, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(calibratedWhite: 0.78, alpha: 1))
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 {
                    block.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.97, alpha: 1)
                }

                let para = NSMutableParagraphStyle()
                para.textBlocks = [block]
                let label = r == 0 ? "Header \(c + 1)\n" : "Cell \(r),\(c + 1)\n"
                let cellAttr = NSAttributedString(
                    string: label,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13.5, weight: r == 0 ? .semibold : .regular),
                        .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1),
                        .paragraphStyle: para
                    ]
                )
                result.append(cellAttr)
            }
        }
        result.append(NSAttributedString(string: "\n"))
        let pos = tv.selectedRange().location
        storage.insert(result, at: pos)
        tv.setSelectedRange(NSRange(location: pos + result.length, length: 0))
        isDirty = true
        updateStats()
    }

    public func insertTeachingCallout(kind: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let bg: NSColor
        let accent: NSColor
        switch kind {
        case "Example":
            bg = NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1)
            accent = NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.72, alpha: 1)
        case "Exercise":
            bg = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            accent = NSColor(calibratedRed: 0.72, green: 0.38, blue: 0.02, alpha: 1)
        default:
            bg = NSColor(calibratedRed: 0.93, green: 0.98, blue: 0.97, alpha: 1)
            accent = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.45, alpha: 1)
        }

        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 14
        para.headIndent = 14
        para.tailIndent = -14
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 8
        para.lineSpacing = 4

        let header = NSAttributedString(
            string: "\n\(kind.uppercased()): ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: accent,
                .backgroundColor: bg,
                .paragraphStyle: para
            ]
        )
        let body = NSAttributedString(
            string: "Explain the concept clearly here with a simple analogy or classroom task.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14.5, weight: .regular),
                .foregroundColor: NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.2, alpha: 1),
                .backgroundColor: bg,
                .paragraphStyle: para
            ]
        )

        let combined = NSMutableAttributedString()
        combined.append(header)
        combined.append(body)

        let pos = tv.selectedRange().location
        storage.insert(combined, at: pos)
        tv.setSelectedRange(NSRange(location: pos + combined.length, length: 0))
        isDirty = true
        updateStats()
    }

    public func insertCodeBlock() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 14
        para.headIndent = 14
        para.lineSpacing = 3
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 8

        let code = NSAttributedString(
            string: "\n// Code Example\nfunction explain(topic) {\n  return `Clear mental model for ${topic}`;\n}\n\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.28, alpha: 1),
                .backgroundColor: NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.97, alpha: 1),
                .paragraphStyle: para
            ]
        )
        let pos = tv.selectedRange().location
        storage.insert(code, at: pos)
        tv.setSelectedRange(NSRange(location: pos + code.length, length: 0))
        isDirty = true
        updateStats()
    }

    public func insertInlineImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url),
              let tv = textView, let storage = tv.textStorage else { return }

        let maxW: CGFloat = 620
        let scale = img.size.width > maxW ? (maxW / img.size.width) : 1.0
        let resized = NSImage(size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
        resized.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: resized.size))
        resized.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = resized
        let attr = NSMutableAttributedString(string: "\n")
        attr.append(NSAttributedString(attachment: attachment))
        attr.append(NSAttributedString(string: "\n"))
        let pos = tv.selectedRange().location
        storage.insert(attr, at: pos)
        tv.setSelectedRange(NSRange(location: pos + attr.length, length: 0))
        isDirty = true
        updateStats()
    }

    // MARK: - Templates & MS Word (.docx) File Management

    public func loadTemplate(_ kind: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let doc = NSMutableAttributedString()
        let titlePara = NSMutableParagraphStyle()
        titlePara.paragraphSpacing = 8

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = 5
        bodyPara.paragraphSpacing = 10

        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1), mono: Bool = false) {
            let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            doc.append(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: size >= 20 ? titlePara : bodyPara]))
        }

        let teal = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.45, alpha: 1)

        switch kind {
        case "Lesson Plan":
            documentTitle = "Lesson Plan"
            add("Lesson Title: Understanding the Concept\n", size: 26, weight: .bold)
            add("1. Why Does This Concept Exist?\n", size: 18, weight: .bold, color: teal)
            add("Start with the real-world problem before introducing any jargon or syntax.\n\n", size: 15)
            add("2. Everyday Analogy\n", size: 18, weight: .bold, color: teal)
            add("Connect the idea to something students already understand in daily life.\n\n", size: 15)
            add("3. Minimal Working Example\n", size: 18, weight: .bold, color: teal)
            add("print('Simple, runnable demonstration')\n\n", size: 13.5, mono: true)
            add("4. Common Mistake & Practice Task\n", size: 18, weight: .bold, color: teal)
            add("• Mistake to watch out for:\n• 5-minute student exercise:\n", size: 15)
        case "Code Walkthrough":
            documentTitle = "Code Walkthrough"
            add("Code Walkthrough & Architecture Notes\n", size: 26, weight: .bold)
            add("Goal\n", size: 18, weight: .bold, color: teal)
            add("Explain how data flows from input to output step by step.\n\n", size: 15)
            add("Step-by-Step Code\n", size: 18, weight: .bold, color: teal)
            add("const items = [1, 2, 3];\nconst doubled = items.map(x => x * 2);\nconsole.log(doubled);\n\n", size: 13.5, mono: true)
            add("Key Takeaway\n", size: 18, weight: .bold, color: teal)
            add("Summarize the mental model in two clear sentences.\n", size: 15)
        default:
            documentTitle = "Untitled Document"
            add("", size: 15)
        }

        storage.setAttributedString(doc)
        currentFileURL = nil
        isDirty = false
        statusMessage = nil
        updateStats()
    }

    public func openDocumentDialog() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [Self.docxType, .rtf, .rtfd, .plainText, .html]
        p.directoryURL = Self.defaultDocsDirectory
        guard p.runModal() == .OK, let url = p.url else { return }
        openDocument(at: url)
    }

    public func openDocument(at url: URL) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            storage.setAttributedString(attr)
            currentFileURL = url
            documentTitle = url.deletingPathExtension().lastPathComponent
            isDirty = false
            updateStats()
            syncFormattingFromSelection()
            statusMessage = "Opened \(url.lastPathComponent)"
        } else {
            statusMessage = "Could not open \(url.lastPathComponent)"
        }
    }

    /// Quick Save: writes directly to current file, or saves a new .docx into ~/Documents/ChronoStream Docs/
    public func quickSave() {
        if let existing = currentFileURL {
            writeDocument(to: existing)
        } else {
            let safeName = sanitizedFileName(documentTitle.isEmpty ? "Untitled Document" : documentTitle)
            let dest = Self.defaultDocsDirectory.appendingPathComponent("\(safeName).docx")
            writeDocument(to: dest)
        }
    }

    /// Save As dialog defaulting to Microsoft Word (.docx)
    public func saveDocumentAs(format: String = "docx") {
        let save = NSSavePanel()
        switch format {
        case "rtf":
            save.allowedContentTypes = [.rtf]
            save.nameFieldStringValue = "\(sanitizedFileName(documentTitle)).rtf"
        case "rtfd":
            save.allowedContentTypes = [.rtfd]
            save.nameFieldStringValue = "\(sanitizedFileName(documentTitle)).rtfd"
        case "html":
            save.allowedContentTypes = [.html]
            save.nameFieldStringValue = "\(sanitizedFileName(documentTitle)).html"
        default:
            save.allowedContentTypes = [Self.docxType, .rtf, .rtfd, .html]
            save.nameFieldStringValue = "\(sanitizedFileName(documentTitle)).docx"
        }
        save.directoryURL = currentFileURL?.deletingLastPathComponent() ?? Self.defaultDocsDirectory
        guard save.runModal() == .OK, let url = save.url else { return }
        writeDocument(to: url)
    }

    private func writeDocument(to url: URL) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let ext = url.pathExtension.lowercased()

        do {
            switch ext {
            case "docx":
                let data = try storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                try data.write(to: url, options: .atomic)
            case "rtfd":
                let wrapper = try storage.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            case "html":
                let data = try storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
                try data.write(to: url, options: .atomic)
            default:
                let data = try storage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: url, options: .atomic)
            }
            currentFileURL = url
            documentTitle = url.deletingPathExtension().lastPathComponent
            isDirty = false
            statusMessage = "Saved \(url.lastPathComponent)"
            refreshSavedDocuments()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    public func deleteSavedDocument(_ entry: SavedDocEntry) {
        try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        if currentFileURL == entry.url {
            currentFileURL = nil
            isDirty = true
        }
        refreshSavedDocuments()
    }

    public func exportPDF() {
        guard let tv = textView else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.directoryURL = currentFileURL?.deletingLastPathComponent() ?? Self.defaultDocsDirectory
        save.nameFieldStringValue = "\(sanitizedFileName(documentTitle)).pdf"
        guard save.runModal() == .OK, let url = save.url else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 595.2, height: 841.8) // A4
        printInfo.topMargin = 48
        printInfo.bottomMargin = 48
        printInfo.leftMargin = 48
        printInfo.rightMargin = 48
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 499, height: 745))
        printView.backgroundColor = .white
        if let storage = tv.textStorage {
            printView.textStorage?.setAttributedString(storage)
        }
        let op = NSPrintOperation(view: printView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
        statusMessage = "Exported \(url.lastPathComponent)"
    }

    // MARK: - Private Helpers

    private func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let clean = trimmed.components(separatedBy: bad).joined(separator: "-")
        return clean.isEmpty ? "Untitled Document" : clean
    }

    private func insertSnippet(_ text: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: resolvedFont(family: fontFamily, size: fontSize),
                .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)
            ]
        )
        let pos = tv.selectedRange().location
        storage.insert(attr, at: pos)
        tv.setSelectedRange(NSRange(location: pos + attr.length, length: 0))
        isDirty = true
        updateStats()
    }

    private func applyFontTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            let cur = (tv.typingAttributes[.font] as? NSFont) ?? resolvedFont(family: fontFamily, size: fontSize)
            let has = fm.traits(of: cur).contains(trait)
            let updated = has ? fm.convert(cur, toNotHaveTrait: trait) : fm.convert(cur, toHaveTrait: trait)
            tv.typingAttributes[.font] = updated
            return
        }
        guard let storage = tv.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { val, subRange, _ in
            let cur = (val as? NSFont) ?? resolvedFont(family: fontFamily, size: fontSize)
            let has = fm.traits(of: cur).contains(trait)
            let updated = has ? fm.convert(cur, toNotHaveTrait: trait) : fm.convert(cur, toHaveTrait: trait)
            storage.addAttribute(.font, value: updated, range: subRange)
        }
        storage.endEditing()
        isDirty = true
    }

    private func resolvedFont(family: String, size: CGFloat) -> NSFont {
        switch family {
        case "Georgia": return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case "Times New Roman": return NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        case "Helvetica Neue": return NSFont(name: "Helvetica Neue", size: size) ?? NSFont.systemFont(ofSize: size)
        case "Mono": return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default: return NSFont.systemFont(ofSize: size)
        }
    }
}

private struct RichTextPaperView: NSViewRepresentable {
    let controller: DocumentEditorController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.backgroundColor = .white
        tv.insertionPointColor = NSColor(calibratedRed: 0, green: 0.5, blue: 0.5, alpha: 1)
        tv.textContainerInset = NSSize(width: 64, height: 56)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator

        scroll.documentView = tv
        controller.textView = tv
        controller.loadTemplate("Lesson Plan")
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? NSTextView {
            let scale = controller.pageZoom
            if abs(scale - context.coordinator.lastScale) > 0.001 {
                let factor = scale / max(0.01, context.coordinator.lastScale)
                tv.scaleUnitSquare(to: NSSize(width: factor, height: factor))
                context.coordinator.lastScale = scale
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: DocumentEditorController
        var lastScale: CGFloat = 1.0
        init(controller: DocumentEditorController) { self.controller = controller }

        @MainActor
        func textDidChange(_ notification: Notification) {
            controller.isDirty = true
            controller.updateStats()
        }

        @MainActor
        func textViewDidChangeSelection(_ notification: Notification) {
            controller.syncFormattingFromSelection()
        }
    }
}

public struct DocumentStudioView: View {
    @State private var editor = DocumentEditorController()
    @State private var docSearch = ""

    public init() {}

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(editor.wordCount) / 200.0)))
    }

    private var filteredSavedDocs: [SavedDocEntry] {
        let q = docSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return editor.savedDocuments }
        return editor.savedDocuments.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var activeFormatBadge: String {
        editor.currentFileURL?.pathExtension.uppercased() ?? "DOCX"
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Saved Documents Panel (MS Word / Pages style)
            if editor.showDocsSidebar && !editor.teachingFocusMode {
                savedDocumentsPanel
                    .frame(width: 235)
                Divider()
            }

            // Main Word Processor Column
            VStack(spacing: 0) {
                topDocumentBar
                Divider()
                if !editor.teachingFocusMode {
                    formattingRibbon
                    Divider()
                }
                paperWorkspace
                Divider()
                bottomStatusBar
            }
        }
    }

    // MARK: - Saved Documents Panel

    private var savedDocumentsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Documents")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editor.loadTemplate("Blank")
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("New Blank Document")

                Button {
                    editor.openDocumentDialog()
                } label: {
                    Image(systemName: "folder")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("Open .docx / .rtf from Mac")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter saved docs…", text: $docSearch)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            if filteredSavedDocs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.richtext")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No saved documents yet")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Press Save (⌘S) to store .docx files in ChronoStream Docs.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSavedDocs) { doc in
                            let isActive = editor.currentFileURL == doc.url
                            Button {
                                editor.openDocument(at: doc.url)
                            } label: {
                                HStack(spacing: 9) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(doc.ext == "DOCX" ? Color.blue.opacity(0.14) : Color.teal.opacity(0.14))
                                            .frame(width: 30, height: 34)
                                        Text(doc.ext)
                                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(doc.ext == "DOCX" ? Color.blue : Color.teal)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(doc.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(doc.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(MediaFormatting.byteString(doc.fileSize))")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") { editor.openDocument(at: doc.url) }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([doc.url])
                                }
                                Divider()
                                Button("Move to Trash", role: .destructive) {
                                    editor.deleteSavedDocument(doc)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            HStack {
                Button {
                    NSWorkspace.shared.open(DocumentEditorController.defaultDocsDirectory)
                } label: {
                    Label("Open Docs Folder", systemImage: "folder.badge.gearshape")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(editor.savedDocuments.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Top Document Title & Save Bar

    private var topDocumentBar: some View {
        HStack(spacing: 10) {
            if !editor.teachingFocusMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        editor.showDocsSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Toggle Saved Documents Panel")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: "doc.text.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            TextField("Document Title", text: $editor.documentTitle)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 260)

            Text(activeFormatBadge)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())

            HStack(spacing: 4) {
                Circle()
                    .fill(editor.isDirty ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(editor.isDirty ? "Unsaved" : "Saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu("Templates") {
                Button("Blank Page") { editor.loadTemplate("Blank") }
                Button("Lesson Plan (Teaching)") { editor.loadTemplate("Lesson Plan") }
                Button("Code Walkthrough") { editor.loadTemplate("Code Walkthrough") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                editor.quickSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save as Microsoft Word (.docx)")

            Menu {
                Button("Microsoft Word (.docx)…") { editor.saveDocumentAs(format: "docx") }
                Button("Rich Text with Images (.rtfd)…") { editor.saveDocumentAs(format: "rtfd") }
                Button("Rich Text (.rtf)…") { editor.saveDocumentAs(format: "rtf") }
                Button("Web Page (.html)…") { editor.saveDocumentAs(format: "html") }
                Divider()
                Button("Export as PDF…") { editor.exportPDF() }
            } label: {
                Label("Export", systemImage: "arrow.up.doc")
            }
            .menuStyle(.borderedButton)
            .fixedSize()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    editor.teachingFocusMode.toggle()
                }
            } label: {
                Label(
                    editor.teachingFocusMode ? "Exit Focus" : "Teach Mode",
                    systemImage: editor.teachingFocusMode ? "arrow.down.right.and.arrow.up.left" : "person.and.background.dotted"
                )
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - MS Word / Pages Style Formatting Ribbon

    private var formattingRibbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Undo / Redo
                ribbonIconButton("arrow.uturn.backward", help: "Undo (⌘Z)") { editor.undo() }
                ribbonIconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)") { editor.redo() }

                Divider().frame(height: 18).padding(.horizontal, 2)

                // Paragraph Style
                Menu("Styles") {
                    Button("Title") { editor.applyTextStyle("Title") }
                    Button("Heading 1") { editor.applyTextStyle("Heading 1") }
                    Button("Heading 2") { editor.applyTextStyle("Heading 2") }
                    Button("Heading 3") { editor.applyTextStyle("Heading 3") }
                    Divider()
                    Button("Normal Body") { editor.applyTextStyle("Body") }
                    Button("Quote") { editor.applyTextStyle("Quote") }
                    Button("Inline Code") { editor.applyTextStyle("Code") }
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                // Font Family
                Picker("", selection: Binding(
                    get: { editor.fontFamily },
                    set: { editor.applyFont(family: $0, size: editor.fontSize) }
                )) {
                    Text("SF Pro").tag("System")
                    Text("Georgia").tag("Georgia")
                    Text("Times New Roman").tag("Times New Roman")
                    Text("Helvetica Neue").tag("Helvetica Neue")
                    Text("Menlo Mono").tag("Mono")
                }
                .frame(width: 124)

                // Font Size
                Picker("", selection: Binding(
                    get: { editor.fontSize },
                    set: { editor.applyFont(family: editor.fontFamily, size: $0) }
                )) {
                    ForEach([CGFloat(10), 11, 12, 14, 15, 16, 18, 20, 24, 28, 36, 48], id: \.self) { sz in
                        Text("\(Int(sz)) pt").tag(sz)
                    }
                }
                .frame(width: 68)

                Divider().frame(height: 18).padding(.horizontal, 2)

                // B / I / U / S with active highlights
                ribbonIconButton("bold", active: editor.isBold, help: "Bold (⌘B)") { editor.toggleBold() }
                ribbonIconButton("italic", active: editor.isItalic, help: "Italic (⌘I)") { editor.toggleItalic() }
                ribbonIconButton("underline", active: editor.isUnderline, help: "Underline (⌘U)") { editor.toggleUnderline() }
                ribbonIconButton("strikethrough", active: editor.isStrikethrough, help: "Strikethrough") { editor.toggleStrikethrough() }

                Divider().frame(height: 18).padding(.horizontal, 2)

                // Text Color & Highlighter
                Menu {
                    Button("Ink Black") { editor.applyTextColor(NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)) }
                    Button("Teal Accent") { editor.applyTextColor(NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.45, alpha: 1)) }
                    Button("Word Blue") { editor.applyTextColor(NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.72, alpha: 1)) }
                    Button("Crimson") { editor.applyTextColor(NSColor(calibratedRed: 0.72, green: 0.12, blue: 0.16, alpha: 1)) }
                    Button("Slate Gray") { editor.applyTextColor(NSColor(calibratedWhite: 0.42, alpha: 1)) }
                } label: {
                    Image(systemName: "textformat")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help("Text Color")

                Menu {
                    Button("Yellow Highlight") { editor.applyHighlight(NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.65, alpha: 1)) }
                    Button("Soft Teal Highlight") { editor.applyHighlight(NSColor(calibratedRed: 0.82, green: 0.96, blue: 0.95, alpha: 1)) }
                    Button("Mint Highlight") { editor.applyHighlight(NSColor(calibratedRed: 0.85, green: 0.97, blue: 0.87, alpha: 1)) }
                    Button("Rose Highlight") { editor.applyHighlight(NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.9, alpha: 1)) }
                    Divider()
                    Button("Clear Highlight") { editor.applyHighlight(nil) }
                } label: {
                    Image(systemName: "highlighter")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help("Highlighter")

                Divider().frame(height: 18).padding(.horizontal, 2)

                // Alignment
                ribbonIconButton("text.alignleft", active: editor.alignment == .left, help: "Align Left") { editor.setAlignment(.left) }
                ribbonIconButton("text.aligncenter", active: editor.alignment == .center, help: "Center") { editor.setAlignment(.center) }
                ribbonIconButton("text.alignright", active: editor.alignment == .right, help: "Align Right") { editor.setAlignment(.right) }
                ribbonIconButton("text.justify", active: editor.alignment == .justified, help: "Justify") { editor.setAlignment(.justified) }

                Menu {
                    Button("Single (1.0×)") { editor.setLineSpacing(1.0) }
                    Button("Comfortable (1.25×)") { editor.setLineSpacing(1.25) }
                    Button("1.5× Spacing") { editor.setLineSpacing(1.5) }
                    Button("Double (2.0×)") { editor.setLineSpacing(2.0) }
                } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help("Line Spacing")

                Divider().frame(height: 18).padding(.horizontal, 2)

                // Lists, Tables & Teaching Blocks
                ribbonIconButton("list.bullet", help: "Bullet List") { editor.insertBulletList() }
                ribbonIconButton("list.number", help: "Numbered List") { editor.insertNumberedList() }
                ribbonIconButton("tablecells", help: "Insert 3×3 Table") { editor.insertTable() }
                ribbonIconButton("photo.badge.plus", help: "Insert Image / Diagram") { editor.insertInlineImage() }

                Menu("Insert") {
                    Button("Key Concept Box") { editor.insertTeachingCallout(kind: "Key Concept") }
                    Button("Example Box") { editor.insertTeachingCallout(kind: "Example") }
                    Button("Student Exercise Box") { editor.insertTeachingCallout(kind: "Exercise") }
                    Divider()
                    Button("Code Block") { editor.insertCodeBlock() }
                    Button("3×3 Table") { editor.insertTable(rows: 3, cols: 3) }
                    Button("4×4 Table") { editor.insertTable(rows: 4, cols: 4) }
                    Button("Horizontal Divider") { editor.insertHorizontalRule() }
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                Divider().frame(height: 18).padding(.horizontal, 2)

                ribbonIconButton("magnifyingglass", help: "Find & Replace (⌘F)") { editor.openFindBar() }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func ribbonIconButton(_ symbol: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: active ? .bold : .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Paper Canvas

    private var paperWorkspace: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            RichTextPaperView(controller: editor)
                .frame(maxWidth: editor.teachingFocusMode ? 900 : 816)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.14), radius: 18, y: 5)
                .padding(.vertical, 24)
                .padding(.horizontal, 22)
        }
    }

    // MARK: - Status Bar

    private var bottomStatusBar: some View {
        HStack(spacing: 14) {
            Text("Page 1 of \(editor.pageCount)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)

            Text("· \(editor.wordCount) words · \(editor.charCount) chars · ~\(readingMinutes) min read")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let msg = editor.statusMessage {
                Text("· \(msg)")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                Text("Zoom").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $editor.pageZoom) {
                    Text("75%").tag(CGFloat(0.75))
                    Text("100%").tag(CGFloat(1.0))
                    Text("125%").tag(CGFloat(1.25))
                    Text("150%").tag(CGFloat(1.5))
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
