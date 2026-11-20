import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum PhotoStudioTab: String, CaseIterable, Identifiable {
    case edit = "Photo Editor"
    case collage = "Collage"
    case gif = "GIF Maker"
    var id: String { rawValue }
}

private struct TextOverlayItem: Identifiable {
    let id = UUID()
    var text: String
    var normalizedPosition: CGPoint // 0...1 in canvas space
    var fontSize: CGFloat
    var color: Color
}

private enum CollageLayout: String, CaseIterable, Identifiable {
    case sideBySide = "2 Side by Side"
    case stacked = "2 Stacked"
    case grid2x2 = "2×2 Grid"
    var id: String { rawValue }
}

public struct PhotoStudioView: View {
    @Bindable var store: LibraryStore
    @State private var activeTab: PhotoStudioTab = .edit

    // Single Photo Editor state
    @State private var selectedPhotoURL: URL?
    @State private var loadedImage: NSImage?
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1.0
    @State private var saturation: Double = 1.0
    @State private var rotationDegrees: Double = 0
    @State private var flipHorizontal: Bool = false

    @State private var textOverlays: [TextOverlayItem] = []
    @State private var selectedOverlayID: UUID?
    @State private var newTextDraft: String = "Caption"
    @State private var newTextSize: CGFloat = 34
    @State private var newTextColor: Color = .white

    // Collage state
    @State private var collageURLs: [URL] = []
    @State private var collageLayout: CollageLayout = .sideBySide
    @State private var collageSpacing: CGFloat = 12

    // GIF Maker state
    @State private var gifSourceIsVideo: Bool = false
    @State private var gifPhotoURLs: [URL] = []
    @State private var gifVideoURL: URL?
    @State private var gifFps: Int = 8
    @State private var gifStartSec: Double = 0
    @State private var gifDurationSec: Double = 4
    @State private var gifWidth: Int = 480

    @State private var statusBanner: String?
    @State private var isExporting: Bool = false

    public init(store: LibraryStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Studio top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo Studio")
                        .font(.headline)
                    Text("Crop, add movable text, build collages, and create animated GIFs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Mode", selection: $activeTab) {
                    ForEach(PhotoStudioTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch activeTab {
                case .edit:
                    singlePhotoEditor
                case .collage:
                    collageStudio
                case .gif:
                    gifStudio
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let msg = statusBanner {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.caption)
                    Spacer()
                    Button("Dismiss") { statusBanner = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    // MARK: - 1. Single Photo Editor (Crop + Draggable Text + Adjustments)

    private var singlePhotoEditor: some View {
        HSplitView {
            // Canvas Area
            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let img = loadedImage {
                    GeometryReader { geo in
                        let canvasSize = fitSize(imageSize: img.size, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 48))
                        ZStack {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .brightness(brightness)
                                .contrast(contrast)
                                .saturation(saturation)
                                .scaleEffect(x: flipHorizontal ? -1 : 1, y: 1)
                                .rotationEffect(.degrees(rotationDegrees))
                                .frame(width: canvasSize.width, height: canvasSize.height)

                            // Visual Crop Overlay
                            if cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 {
                                let rectX = canvasSize.width * cropLeft
                                let rectY = canvasSize.height * cropTop
                                let rectW = max(10, canvasSize.width * (1 - cropLeft - cropRight))
                                let rectH = max(10, canvasSize.height * (1 - cropTop - cropBottom))
                                Rectangle()
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: rectW, height: rectH)
                                    .position(x: rectX + rectW / 2, y: rectY + rectH / 2)
                                    .allowsHitTesting(false)
                            }

                            // Draggable Text Layers
                            ForEach($textOverlays) { $overlay in
                                Text(overlay.text)
                                    .font(.system(size: overlay.fontSize, weight: .bold))
                                    .foregroundStyle(overlay.color)
                                    .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                                    .padding(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(selectedOverlayID == overlay.id ? Color.accentColor : .clear, lineWidth: 1.5)
                                    )
                                    .position(
                                        x: overlay.normalizedPosition.x * canvasSize.width,
                                        y: overlay.normalizedPosition.y * canvasSize.height
                                    )
                                    .gesture(
                                        DragGesture()
                                            .onChanged { val in
                                                selectedOverlayID = overlay.id
                                                let nx = min(0.95, max(0.05, val.location.x / max(1, canvasSize.width)))
                                                let ny = min(0.95, max(0.05, val.location.y / max(1, canvasSize.height)))
                                                overlay.normalizedPosition = CGPoint(x: nx, y: ny)
                                            }
                                    )
                                    .onTapGesture { selectedOverlayID = overlay.id }
                            }
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .clipped()
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Choose a Photo to Edit", systemImage: "photo.badge.plus")
                    } description: {
                        Text("Pick any photo from your Mac to crop, place movable text, and adjust colors.")
                    } actions: {
                        Button("Choose Photo…") { pickSinglePhoto() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(minWidth: 460)

            // Right Inspector Panel
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button("Choose Photo…") { pickSinglePhoto() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Reset") { resetEditor() }
                            .buttonStyle(.borderless)
                            .disabled(loadedImage == nil)
                    }

                    // Crop Controls
                    GroupBox("Crop") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Button("Reset") { cropLeft = 0; cropRight = 0; cropTop = 0; cropBottom = 0 }
                                Button("Square 1:1") { applySquareCrop() }
                                Button("Trim 10%") { cropLeft = 0.05; cropRight = 0.05; cropTop = 0.05; cropBottom = 0.05 }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            labeledSlider("Left", value: $cropLeft, range: 0...0.42)
                            labeledSlider("Right", value: $cropRight, range: 0...0.42)
                            labeledSlider("Top", value: $cropTop, range: 0...0.42)
                            labeledSlider("Bottom", value: $cropBottom, range: 0...0.42)
                        }
                        .padding(.top, 4)
                    }

                    // Text Overlay Controls
                    GroupBox("Text Layer (Drag on Image)") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Enter text…", text: $newTextDraft)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                ColorPicker("Color", selection: $newTextColor)
                                Spacer()
                                Stepper("Size \(Int(newTextSize))", value: $newTextSize, in: 14...96, step: 4)
                                    .font(.caption)
                            }
                            HStack {
                                Button("Add Text") {
                                    let trimmed = newTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    let item = TextOverlayItem(
                                        text: trimmed,
                                        normalizedPosition: CGPoint(x: 0.5, y: 0.5),
                                        fontSize: newTextSize,
                                        color: newTextColor
                                    )
                                    textOverlays.append(item)
                                    selectedOverlayID = item.id
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(loadedImage == nil)

                                if let selID = selectedOverlayID {
                                    Button("Remove Selected", role: .destructive) {
                                        textOverlays.removeAll { $0.id == selID }
                                        selectedOverlayID = nil
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Color & Transform
                    GroupBox("Adjust & Transform") {
                        VStack(alignment: .leading, spacing: 8) {
                            labeledSlider("Brightness", value: $brightness, range: -0.4...0.4)
                            labeledSlider("Contrast", value: $contrast, range: 0.5...1.8)
                            labeledSlider("Saturation", value: $saturation, range: 0...2.0)

                            HStack(spacing: 8) {
                                Button { rotationDegrees -= 90 } label: { Image(systemName: "rotate.left") }
                                Button { rotationDegrees += 90 } label: { Image(systemName: "rotate.right") }
                                Button { flipHorizontal.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }

                    Button {
                        exportEditedPhoto()
                    } label: {
                        Label("Export Edited PNG…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(loadedImage == nil)
                }
                .padding(16)
            }
            .frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - 2. Collage Maker

    private var collageStudio: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Add Photos (2–4)…") { pickCollagePhotos() }
                    .buttonStyle(.borderedProminent)

                Picker("Layout", selection: $collageLayout) {
                    ForEach(CollageLayout.allCases) { layout in
                        Text(layout.rawValue).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                HStack(spacing: 6) {
                    Text("Spacing").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $collageSpacing, in: 0...32).frame(width: 90)
                }

                Spacer()

                Button("Clear") { collageURLs.removeAll() }
                    .disabled(collageURLs.isEmpty)

                Button("Export Collage PNG…") { exportCollage() }
                    .buttonStyle(.borderedProminent)
                    .disabled(collageURLs.count < 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if collageURLs.isEmpty {
                ContentUnavailableView(
                    "Build a Photo Collage",
                    systemImage: "rectangle.grid.2x2",
                    description: Text("Select 2 to 4 photos to arrange into a clean side-by-side, stacked, or 2×2 grid collage.")
                )
            } else {
                collagePreviewCanvas
                    .frame(maxWidth: 760, maxHeight: 500)
                    .padding(16)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var collagePreviewCanvas: some View {
        let images = collageURLs.compactMap { NSImage(contentsOf: $0) }
        Group {
            switch collageLayout {
            case .sideBySide:
                HStack(spacing: collageSpacing) {
                    ForEach(Array(images.prefix(2).enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                    }
                }
            case .stacked:
                VStack(spacing: collageSpacing) {
                    ForEach(Array(images.prefix(2).enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                    }
                }
            case .grid2x2:
                VStack(spacing: collageSpacing) {
                    HStack(spacing: collageSpacing) {
                        ForEach(Array(images.prefix(2).enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                        }
                    }
                    if images.count > 2 {
                        HStack(spacing: collageSpacing) {
                            ForEach(Array(images.dropFirst(2).prefix(2).enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                            }
                        }
                    }
                }
            }
        }
        .padding(collageSpacing)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 12)
    }

    // MARK: - 3. Animated GIF Maker

    private var gifStudio: some View {
        Form {
            Section("Source") {
                Picker("Create GIF From", selection: $gifSourceIsVideo) {
                    Text("Multiple Photos").tag(false)
                    Text("Video Clip").tag(true)
                }
                .pickerStyle(.segmented)

                if gifSourceIsVideo {
                    HStack {
                        Text(gifVideoURL?.lastPathComponent ?? "No video selected")
                            .foregroundStyle(gifVideoURL == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose Video…") { pickGifVideo() }
                    }
                    HStack {
                        Text("Start (sec)")
                        TextField("0", value: $gifStartSec, format: .number).frame(width: 70)
                        Text("Duration (sec)")
                        TextField("4", value: $gifDurationSec, format: .number).frame(width: 70)
                    }
                } else {
                    HStack {
                        Text(gifPhotoURLs.isEmpty ? "No photos selected" : "\(gifPhotoURLs.count) photos selected")
                            .foregroundStyle(gifPhotoURLs.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose Photos…") { pickGifPhotos() }
                    }
                }
            }

            Section("GIF Settings") {
                Stepper("Frame Rate: \(gifFps) FPS", value: $gifFps, in: 2...20)
                Stepper("Width: \(gifWidth) px", value: $gifWidth, in: 240...960, step: 60)
            }

            Section {
                HStack {
                    if isExporting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Create & Save Animated GIF…") { exportGIF() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isExporting || (gifSourceIsVideo ? gifVideoURL == nil : gifPhotoURLs.count < 2))
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .padding(.top, 16)
    }

    // MARK: - Helpers & Export Pipelines

    private func labeledSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    private func fitSize(imageSize: NSSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGSize(width: 300, height: 200)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func applySquareCrop() {
        guard let img = loadedImage, img.size.width > 0, img.size.height > 0 else { return }
        if img.size.width > img.size.height {
            let trim = (1.0 - (img.size.height / img.size.width)) / 2.0
            cropLeft = trim; cropRight = trim; cropTop = 0; cropBottom = 0
        } else {
            let trim = (1.0 - (img.size.width / img.size.height)) / 2.0
            cropTop = trim; cropBottom = trim; cropLeft = 0; cropRight = 0
        }
    }

    private func resetEditor() {
        cropLeft = 0; cropRight = 0; cropTop = 0; cropBottom = 0
        brightness = 0; contrast = 1.0; saturation = 1.0
        rotationDegrees = 0; flipHorizontal = false
        textOverlays.removeAll(); selectedOverlayID = nil
    }

    private func pickSinglePhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url {
            selectedPhotoURL = u
            loadedImage = NSImage(contentsOf: u)
            resetEditor()
        }
    }

    private func pickCollagePhotos() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            collageURLs = Array(p.urls.prefix(4))
        }
    }

    private func pickGifPhotos() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { gifPhotoURLs = p.urls }
    }

    private func pickGifVideo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        if p.runModal() == .OK { gifVideoURL = p.url }
    }

    private func exportEditedPhoto() {
        guard let img = loadedImage else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = (selectedPhotoURL?.deletingPathExtension().lastPathComponent ?? "photo") + "_edited.png"
        guard save.runModal() == .OK, let outURL = save.url else { return }

        let targetW = min(2400.0, max(400.0, img.size.width))
        let targetH = targetW * (img.size.height / max(1, img.size.width))
        let fullSize = CGSize(width: targetW, height: targetH)

        let renderedView = ZStack {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .brightness(brightness)
                .contrast(contrast)
                .saturation(saturation)
                .scaleEffect(x: flipHorizontal ? -1 : 1, y: 1)
                .rotationEffect(.degrees(rotationDegrees))
                .frame(width: fullSize.width, height: fullSize.height)

            ForEach(textOverlays) { overlay in
                Text(overlay.text)
                    .font(.system(size: overlay.fontSize * (fullSize.width / 640.0), weight: .bold))
                    .foregroundStyle(overlay.color)
                    .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
                    .position(x: overlay.normalizedPosition.x * fullSize.width, y: overlay.normalizedPosition.y * fullSize.height)
            }
        }
        .frame(width: fullSize.width, height: fullSize.height)

        let renderer = ImageRenderer(content: renderedView)
        renderer.scale = 1.0
        guard let fullCG = renderer.cgImage else { return }

        let cx = CGFloat(cropLeft) * CGFloat(fullCG.width)
        let cy = CGFloat(cropTop) * CGFloat(fullCG.height)
        let cw = max(16, CGFloat(1 - cropLeft - cropRight) * CGFloat(fullCG.width))
        let ch = max(16, CGFloat(1 - cropTop - cropBottom) * CGFloat(fullCG.height))
        let finalCG = fullCG.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) ?? fullCG

        let rep = NSBitmapImageRep(cgImage: finalCG)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outURL)
            statusBanner = "Saved edited photo to \(outURL.lastPathComponent)"
        }
    }

    private func exportCollage() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "ChronoStream_Collage.png"
        guard save.runModal() == .OK, let outURL = save.url else { return }

        let view = collagePreviewCanvas.frame(width: 1600, height: 1000)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
        if let cg = renderer.cgImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outURL)
                statusBanner = "Saved collage to \(outURL.lastPathComponent)"
            }
        }
    }

    private func exportGIF() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.gif]
        save.nameFieldStringValue = "ChronoStream.gif"
        guard save.runModal() == .OK, let outURL = save.url else { return }

        isExporting = true
        if gifSourceIsVideo, let videoURL = gifVideoURL {
            let start = gifStartSec
            let dur = gifDurationSec
            let fps = gifFps
            let w = gifWidth
            Task {
                let res = await FFmpegBridge.shared.createGifFromVideo(video: videoURL, startSeconds: start, durationSeconds: dur, fps: fps, width: w, output: outURL)
                isExporting = false
                switch res {
                case .success: statusBanner = "Saved animated GIF to \(outURL.lastPathComponent)"
                case .failure(let err): statusBanner = err.localizedDescription
                }
            }
        } else {
            let urls = gifPhotoURLs
            let delay = 1.0 / Double(max(1, gifFps))
            let maxW = gifWidth
            Task.detached(priority: .userInitiated) {
                let ok = Self.writeGifFromImages(urls: urls, delay: delay, maxPixelSize: maxW, to: outURL)
                await MainActor.run {
                    isExporting = false
                    statusBanner = ok ? "Saved animated GIF to \(outURL.lastPathComponent)" : "Could not create GIF from selected photos."
                }
            }
        }
    }

    private nonisolated static func writeGifFromImages(urls: [URL], delay: Double, maxPixelSize: Int, to outURL: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.gif.identifier as CFString, urls.count, nil) else {
            return false
        }
        let fileProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]

        for u in urls {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { continue }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }
        }
        return CGImageDestinationFinalize(dest)
    }
}
