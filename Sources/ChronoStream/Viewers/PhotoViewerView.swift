import AppKit
import ImageIO
import SwiftUI

/// Native Preview/Photos-inspired image viewer with smooth zoom, rotation, slideshow, and keyboard navigation.
public struct PhotoViewerView: View {
    let item: MediaItem
    let siblings: [MediaItem]
    let slideshowInterval: Double
    let onSelect: (MediaItem) -> Void
    let onShare: () -> Void
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var pixelSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var rotationDegrees: Double = 0
    @State private var isSlideshowActive: Bool = false
    @State private var slideshowTask: Task<Void, Never>?

    public init(
        item: MediaItem,
        siblings: [MediaItem],
        slideshowInterval: Double,
        onSelect: @escaping (MediaItem) -> Void,
        onShare: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.siblings = siblings
        self.slideshowInterval = slideshowInterval
        self.onSelect = onSelect
        self.onShare = onShare
        self.onClose = onClose
    }

    private var currentIndex: Int? {
        siblings.firstIndex(where: { $0.id == item.id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if pixelSize.width > 0 {
                        Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) · \(item.fileExtension) · \(MediaFormatting.byteString(item.fileSize))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Button { navigate(delta: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(siblings.count <= 1)
                    .help("Previous Photo")

                    Button { navigate(delta: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(siblings.count <= 1)
                    .help("Next Photo")

                    Divider().frame(height: 16)

                    Button { rotationDegrees -= 90 } label: {
                        Image(systemName: "rotate.left")
                    }
                    .help("Rotate Left")

                    Button { rotationDegrees += 90 } label: {
                        Image(systemName: "rotate.right")
                    }
                    .help("Rotate Right")

                    Divider().frame(height: 16)

                    Button { zoomScale = max(0.25, zoomScale - 0.25) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text("\(Int(zoomScale * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 42)
                    Button { zoomScale = min(5.0, zoomScale + 0.25) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Button("Fit") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoomScale = 1.0
                            rotationDegrees = 0
                        }
                    }

                    Divider().frame(height: 16)

                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share via AirDrop or Wi-Fi QR (Android & iPhone)")

                    Button {
                        toggleSlideshow()
                    } label: {
                        Label(isSlideshowActive ? "Stop" : "Slideshow", systemImage: isSlideshowActive ? "stop.fill" : "play.rectangle")
                    }
                    .tint(isSlideshowActive ? .accentColor : nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Canvas
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        if let nsImg = image {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    width: max(geo.size.width, geo.size.width * zoomScale),
                                    height: max(geo.size.height, geo.size.height * zoomScale)
                                )
                                .rotationEffect(.degrees(rotationDegrees))
                                .animation(.easeOut(duration: 0.18), value: rotationDegrees)
                                .animation(.easeOut(duration: 0.16), value: zoomScale)
                                .gesture(
                                    MagnifyGesture()
                                        .onChanged { val in
                                            zoomScale = max(0.25, min(5.0, val.magnification))
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        zoomScale = zoomScale > 1.1 ? 1.0 : 2.25
                                    }
                                }
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear { loadImage() }
        .onChange(of: item.id) { _, _ in
            zoomScale = 1.0
            rotationDegrees = 0
            loadImage()
        }
        .onDisappear {
            stopSlideshow()
        }
    }

    private func loadImage() {
        let url = item.url
        image = nil
        Task.detached(priority: .userInitiated) {
            // Decode safely with CGImageSource capped at 4096px for low-RAM responsiveness
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let pw = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let ph = (props?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            await MainActor.run {
                self.pixelSize = CGSize(width: pw > 0 ? pw : CGFloat(cg.width), height: ph > 0 ? ph : CGFloat(cg.height))
                self.image = nsImg
            }
        }
    }

    private func navigate(delta: Int) {
        guard let idx = currentIndex, !siblings.isEmpty else { return }
        let next = (idx + delta + siblings.count) % siblings.count
        onSelect(siblings[next])
    }

    private func toggleSlideshow() {
        if isSlideshowActive {
            stopSlideshow()
        } else {
            isSlideshowActive = true
            let intervalNs = UInt64(max(1.0, slideshowInterval) * 1_000_000_000)
            slideshowTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: intervalNs)
                    if Task.isCancelled { break }
                    navigate(delta: 1)
                }
            }
        }
    }

    private func stopSlideshow() {
        isSlideshowActive = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }
}
