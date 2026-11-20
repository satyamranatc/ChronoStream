import AppKit
import AVFoundation
import ImageIO
import PDFKit
@preconcurrency import QuickLookThumbnailing

/// Bounded, lazy, off-main-thread thumbnail cache. Never loads full-resolution originals into memory for grid browsing.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskCacheDir: URL
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let maxDiskBytes: Int64 = 300 * 1024 * 1024 // 300 MB disk cap

    private init() {
        memoryCache.countLimit = 450
        memoryCache.totalCostLimit = 72 * 1024 * 1024 // 72 MB RAM cap

        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.diskCacheDir = caches.appendingPathComponent("ChronoStream/Thumbnails", isDirectory: true)
        try? fm.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    public func thumbnail(for item: MediaItem, maxPixelSize: Int = 360) async -> NSImage? {
        let key = cacheKey(for: item, size: maxPixelSize)
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            if Task.isCancelled { return nil }
            let diskURL = diskCacheDir.appendingPathComponent("\(key).jpg")
            if let data = try? Data(contentsOf: diskURL), let img = NSImage(data: data) {
                memoryCache.setObject(img, forKey: key as NSString, cost: data.count)
                return img
            }

            let generated = await generateThumbnail(for: item, maxPixelSize: maxPixelSize)
            if Task.isCancelled { return nil }
            if let img = generated {
                let cost = Int(img.size.width * img.size.height * 4)
                memoryCache.setObject(img, forKey: key as NSString, cost: cost)
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) {
                    try? jpg.write(to: diskURL, options: .atomic)
                }
            }
            return generated
        }

        inFlight[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[key] = nil
        return result
    }

    public func clearAll() {
        memoryCache.removeAllObjects()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: diskCacheDir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    public func diskUsageBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskCacheDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for f in files {
            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    private func cacheKey(for item: MediaItem, size: Int) -> String {
        let raw = "\(item.path)|\(item.fileSize)|\(Int(item.modifiedDate.timeIntervalSince1970))|\(size)"
        var hash: UInt64 = 14695981039346656037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func generateThumbnail(for item: MediaItem, maxPixelSize: Int) async -> NSImage? {
        if Task.isCancelled { return nil }
        switch item.kind {
        case .image:
            return decodeImageThumbnail(url: item.url, maxPixelSize: maxPixelSize)
        case .pdf:
            return renderPDFThumbnail(url: item.url, maxPixelSize: maxPixelSize)
        case .audio:
            return await extractAudioArtwork(url: item.url, maxPixelSize: maxPixelSize)
        case .video:
            // Fast-path: skip QuickLook/AVAssetImageGenerator for MPEG-PS / MKV / AVI so bottom items render immediately
            let compat = MediaFormatRegistry.inspectCompatibility(for: item.url)
            if Task.isCancelled { return nil }
            if compat == .ffmpegRemux {
                return await FFmpegBridge.shared.extractThumbnail(for: item.url, at: 2.0, width: maxPixelSize)
            }
            if let ql = await generateQuickLookThumbnail(url: item.url, size: maxPixelSize) {
                return ql
            }
            if Task.isCancelled { return nil }
            if let av = await generateAVVideoThumbnail(url: item.url, maxPixelSize: maxPixelSize) {
                return av
            }
            if Task.isCancelled { return nil }
            return await FFmpegBridge.shared.extractThumbnail(for: item.url, at: 2.0, width: maxPixelSize)
        }
    }

    private func decodeImageThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func renderPDFThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(bounds.width, bounds.height)
        let target = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        return page.thumbnail(of: target, for: .mediaBox)
    }

    private func extractAudioArtwork(url: URL, maxPixelSize: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }

    private func generateQuickLookThumbnail(url: URL, size: Int) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }

    private func generateAVVideoThumbnail(url: URL, maxPixelSize: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        if let result = try? await gen.image(at: time) {
            return NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        }
        return nil
    }
}
