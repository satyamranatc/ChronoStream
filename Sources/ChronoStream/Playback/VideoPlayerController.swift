import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

// MARK: - Real-Time GPU Video Enhancement Engine (Metal-Backed CoreImage)

public enum VideoEnhanceMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case enhanced = "Enhanced"
    case cctvClarity = "CCTV Clarity"
    case ultraCrisp = "Ultra Crisp"

    public var id: String { rawValue }

    public var subtitle: String {
        switch self {
        case .off: return "Original unmodified video"
        case .enhanced: return "Balanced GPU denoise, contrast & sharpening"
        case .cctvClarity: return "Blurry faces, number plates & dark CCTV footage"
        case .ultraCrisp: return "Maximum edge clarity & detail restoration"
        }
    }

    public var defaultParams: VideoEnhanceParams {
        switch self {
        case .off:
            return VideoEnhanceParams(enabled: false, sharpness: 0, denoise: 0, shadowLift: 0, contrast: 1.0, saturation: 1.0)
        case .enhanced:
            return VideoEnhanceParams(enabled: true, sharpness: 0.45, denoise: 0.015, shadowLift: 0.12, contrast: 1.07, saturation: 1.06)
        case .cctvClarity:
            return VideoEnhanceParams(enabled: true, sharpness: 1.05, denoise: 0.035, shadowLift: 0.46, contrast: 1.15, saturation: 1.04)
        case .ultraCrisp:
            return VideoEnhanceParams(enabled: true, sharpness: 1.35, denoise: 0.025, shadowLift: 0.30, contrast: 1.12, saturation: 1.08)
        }
    }
}

public struct VideoEnhanceParams: Equatable, Sendable {
    public var enabled: Bool
    public var sharpness: Double     // 0.0 ... 2.0
    public var denoise: Double       // 0.0 ... 0.08
    public var shadowLift: Double    // 0.0 ... 0.8
    public var contrast: Double      // 0.85 ... 1.4
    public var saturation: Double    // 0.7 ... 1.4
}

private final class LiveEnhancementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var params: VideoEnhanceParams = VideoEnhanceMode.off.defaultParams
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func update(_ next: VideoEnhanceParams) {
        lock.lock()
        params = next
        lock.unlock()
    }

    func snapshot() -> VideoEnhanceParams {
        lock.lock()
        defer { lock.unlock() }
        return params
    }
}

public struct SubtitleCue: Identifiable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let text: String
}

public enum SubtitleParser {
    /// Parses external .srt and .vtt subtitle files safely.
    public static func parse(url: URL) -> [SubtitleCue] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var idx = 0

        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let arrowIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[arrowIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }
            let textLines = lines.dropFirst(arrowIdx + 1)
            let text = textLines.joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !text.isEmpty {
                idx += 1
                cues.append(SubtitleCue(id: idx, startTime: start, endTime: end, text: text))
            }
        }
        return cues
    }

    public static func parseTimestamp(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let clean = token.replacingOccurrences(of: ",", with: ".")
        let parts = clean.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        }
    }
}

/// High-speed persistent scrub preview engine:
/// - Keeps a single warm AVAssetImageGenerator per video (no per-hover decoder init)
/// - Pre-warms 40 evenly spaced keyframes in the background for 0ms instant scrubbing
/// - Provides synchronous O(1) nearest-frame RAM lookup on mouse move
/// - Uses latest-wins coalescing so rapid cursor movement never stalls or drops frames
private final class ScrubPreviewEngine: @unchecked Sendable {
    private let decodeQueue = DispatchQueue(label: "com.chronostream.scrubPreview", qos: .userInteractive)
    private let cacheLock = NSLock()

    // Protected by cacheLock for 0ms synchronous reads on MainActor
    private var exactCache: [Int: NSImage] = [:]
    private var filmstrip: [(time: Double, image: NSImage)] = []
    private var bucketSeconds: Double = 1.0

    // Protected by decodeQueue
    private var generator: AVAssetImageGenerator?
    private var prewarmGenerator: AVAssetImageGenerator?
    private var generation: Int = 0
    private var pendingTime: Double?
    private var pendingCallback: (@Sendable (NSImage) -> Void)?
    private var isDecodingLive = false

    func configure(url: URL, duration: Double) {
        let bucket = max(0.5, duration / 240.0)
        cacheLock.lock()
        exactCache.removeAll()
        filmstrip.removeAll()
        bucketSeconds = bucket
        cacheLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            let gen = self.generation
            self.generator?.cancelAllCGImageGeneration()
            self.prewarmGenerator?.cancelAllCGImageGeneration()
            self.prewarmGenerator = nil
            self.pendingTime = nil
            self.pendingCallback = nil
            self.isDecodingLive = false

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let imgGen = AVAssetImageGenerator(asset: asset)
            imgGen.appliesPreferredTrackTransform = true
            imgGen.maximumSize = CGSize(width: 240, height: 135)
            // Generous keyframe tolerance lets VideoToolbox decode 1 single IDR frame (~8ms)
            let tol = CMTime(seconds: max(1.0, min(4.0, duration / 120.0)), preferredTimescale: 600)
            imgGen.requestedTimeToleranceBefore = tol
            imgGen.requestedTimeToleranceAfter = tol
            self.generator = imgGen

            guard duration > 1 else { return }
            self.prewarmFilmstrip(generator: imgGen, duration: duration, generation: gen)
        }
    }

    func reset() {
        cacheLock.lock()
        exactCache.removeAll()
        filmstrip.removeAll()
        cacheLock.unlock()

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.generator?.cancelAllCGImageGeneration()
            self.prewarmGenerator?.cancelAllCGImageGeneration()
            self.generator = nil
            self.prewarmGenerator = nil
            self.pendingTime = nil
            self.pendingCallback = nil
            self.isDecodingLive = false
        }
    }

    /// 0ms synchronous lookup: returns (image, isExactBucketHit).
    func instantFrame(for seconds: Double) -> (image: NSImage?, exact: Bool) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let key = Int((seconds / bucketSeconds).rounded())
        if let exact = exactCache[key] {
            return (exact, true)
        }
        // Check adjacent cached bucket
        if let prev = exactCache[key - 1] {
            return (prev, false)
        }
        if let next = exactCache[key + 1] {
            return (next, false)
        }
        // Fallback to nearest pre-warmed filmstrip frame for instant visual feedback
        guard !filmstrip.isEmpty else { return (nil, false) }
        var best = filmstrip[0]
        var bestDist = abs(best.time - seconds)
        for entry in filmstrip {
            let d = abs(entry.time - seconds)
            if d < bestDist {
                bestDist = d
                best = entry
            }
        }
        return (best.image, false)
    }

    /// Latest-wins live decode on the warm persistent generator.
    func requestExactFrame(at seconds: Double, onFrame: @escaping @Sendable (NSImage) -> Void) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingTime = seconds
            self.pendingCallback = onFrame
            if !self.isDecodingLive {
                self.drainLiveQueue()
            }
        }
    }

    private func drainLiveQueue() {
        guard let targetTime = pendingTime, let gen = generator else {
            isDecodingLive = false
            return
        }
        let cb = pendingCallback
        pendingTime = nil
        isDecodingLive = true
        let activeGen = generation

        let cm = CMTime(seconds: targetTime, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: cm) { [weak self] cg, _, _ in
            guard let self else { return }
            self.decodeQueue.async {
                guard activeGen == self.generation else {
                    self.isDecodingLive = false
                    return
                }
                if let cg {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cacheLock.lock()
                    let key = Int((targetTime / self.bucketSeconds).rounded())
                    if self.exactCache.count > 260 {
                        self.exactCache.removeAll(keepingCapacity: true)
                    }
                    self.exactCache[key] = img
                    self.cacheLock.unlock()
                    cb?(img)
                }
                if self.pendingTime != nil {
                    self.drainLiveQueue()
                } else {
                    self.isDecodingLive = false
                }
            }
        }
    }

    private func prewarmFilmstrip(generator imgGen: AVAssetImageGenerator, duration: Double, generation gen: Int) {
        let count = 40
        let step = duration / Double(count)
        let times: [NSValue] = (0..<count).map { i in
            let t = Double(i) * step + step * 0.5
            return NSValue(time: CMTime(seconds: min(duration - 0.1, max(0, t)), preferredTimescale: 600))
        }
        // Separate prewarm generator so live hover never contends with filmstrip pre-warming
        let prewarmGen = AVAssetImageGenerator(asset: imgGen.asset)
        prewarmGen.appliesPreferredTrackTransform = true
        prewarmGen.maximumSize = CGSize(width: 240, height: 135)
        prewarmGen.requestedTimeToleranceBefore = imgGen.requestedTimeToleranceBefore
        prewarmGen.requestedTimeToleranceAfter = imgGen.requestedTimeToleranceAfter
        self.prewarmGenerator = prewarmGen

        prewarmGen.generateCGImagesAsynchronously(forTimes: times) { [weak self] requestedTime, cg, _, result, _ in
            guard let self else { return }
            if result != .succeeded || cg == nil { return }
            let sec = CMTimeGetSeconds(requestedTime)
            let img = NSImage(cgImage: cg!, size: NSSize(width: cg!.width, height: cg!.height))

            self.decodeQueue.async {
                guard gen == self.generation else {
                    self.prewarmGenerator?.cancelAllCGImageGeneration()
                    return
                }
                self.cacheLock.lock()
                self.filmstrip.append((time: sec, image: img))
                let key = Int((sec / self.bucketSeconds).rounded())
                self.exactCache[key] = img
                self.cacheLock.unlock()
            }
        }
    }
}

@MainActor
@Observable
public final class VideoPlayerController {
    public let player = AVPlayer()
    public var currentItem: MediaItem?
    public var isPlaying: Bool = false
    public var isLoading: Bool = false
    public var statusMessage: String?
    public var errorMessage: String?

    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Float = 1.0 {
        didSet { player.volume = volume }
    }
    public var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    public var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = playbackRate }
        }
    }

    public var subtitles: [SubtitleCue] = []
    public var activeSubtitleText: String?
    public var hoverPreviewImage: NSImage?

    // Real-time GPU Video Enhancement state
    public var enhanceMode: VideoEnhanceMode = .off
    public var enhanceParams: VideoEnhanceParams = VideoEnhanceMode.off.defaultParams

    private let enhancementBox = LiveEnhancementBox()
    private var currentAsset: AVURLAsset?
    private var enhancementComposition: AVVideoComposition?
    private var timeObserver: Any?
    private var lastSavedPosition: Double = -10
    private let previewEngine = ScrubPreviewEngine()
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0
    private weak var libraryStore: LibraryStore?

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
    }

    public func bind(store: LibraryStore) {
        self.libraryStore = store
        self.playbackRate = Float(store.defaultPlaybackRate)
    }

    public func load(_ item: MediaItem) {
        // Immediately cancel any previous video load/remux and clear old player item
        loadGeneration += 1
        let gen = loadGeneration
        loadTask?.cancel()
        previewEngine.reset()
        stopObserving()
        player.pause()
        player.replaceCurrentItem(with: nil)

        currentItem = item
        isPlaying = false
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        subtitles = []
        activeSubtitleText = nil
        hoverPreviewImage = nil
        currentTime = 0
        duration = item.duration ?? 0
        lastSavedPosition = -10

        loadTask = Task {
            // Inspect magic bytes & load subtitles off the main thread
            let (compat, parsedSubs) = await Task.detached(priority: .userInitiated) { () -> (ContainerCompatibility, [SubtitleCue]) in
                let c = MediaFormatRegistry.inspectCompatibility(for: item.url)
                var subs: [SubtitleCue] = []
                for ext in ["srt", "vtt"] {
                    let subURL = item.url.deletingPathExtension().appendingPathExtension(ext)
                    if FileManager.default.fileExists(atPath: subURL.path) {
                        subs = SubtitleParser.parse(url: subURL)
                        break
                    }
                }
                return (c, subs)
            }.value

            guard !Task.isCancelled, gen == self.loadGeneration else { return }
            self.subtitles = parsedSubs

            let playbackURL: URL
            switch compat {
            case .nativeAVFoundation:
                playbackURL = item.url
            case .ffmpegRemux:
                statusMessage = "Remuxing \(item.fileExtension) container with FFmpeg…"
                if let remuxed = await FFmpegBridge.shared.remuxForPlayback(sourceURL: item.url, isAudioOnly: false) {
                    guard !Task.isCancelled, gen == self.loadGeneration else { return }
                    playbackURL = remuxed
                    statusMessage = nil
                } else {
                    guard !Task.isCancelled, gen == self.loadGeneration else { return }
                    isLoading = false
                    statusMessage = nil
                    errorMessage = "Unsupported container (\(item.fileExtension)). Install FFmpeg via Homebrew or convert to standard MP4."
                    return
                }
            default:
                isLoading = false
                errorMessage = "This file appears corrupted or unsupported."
                return
            }

            guard !Task.isCancelled, gen == self.loadGeneration else { return }
            let asset = AVURLAsset(url: playbackURL)
            do {
                let durTime = try await asset.load(.duration)
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                let durSec = CMTimeGetSeconds(durTime)
                self.duration = durSec.isFinite && durSec > 0 ? durSec : 0
            } catch {
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                self.isLoading = false
                self.errorMessage = "Could not decode video stream: \(error.localizedDescription)"
                return
            }

            guard !Task.isCancelled, gen == self.loadGeneration else { return }
            self.currentAsset = asset
            self.enhancementComposition = nil
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            player.volume = volume
            player.isMuted = isMuted

            if self.enhanceMode != .off {
                await self.attachEnhancementComposition(to: playerItem, asset: asset)
            }

            previewEngine.configure(url: playbackURL, duration: self.duration)
            guard !Task.isCancelled, gen == self.loadGeneration else { return }

            if item.lastPosition > 5 && (self.duration == 0 || item.lastPosition < self.duration - 5) {
                let target = CMTime(seconds: item.lastPosition, preferredTimescale: 600)
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                self.currentTime = item.lastPosition
            }

            startObserving()
            isLoading = false
            play()
        }
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
        savePositionIfNeeded(force: true)
    }

    public func stop() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        previewEngine.reset()
        pause()
        stopObserving()
        player.replaceCurrentItem(with: nil)
        currentAsset = nil
        enhancementComposition = nil
        currentItem = nil
        isLoading = false
        statusMessage = nil
    }

    // MARK: - Live GPU Enhancement Controls

    public func setEnhanceMode(_ mode: VideoEnhanceMode) {
        enhanceMode = mode
        let defaults = mode.defaultParams
        enhanceParams = defaults
        enhancementBox.update(defaults)
        syncEnhancementPipeline()
    }

    public func updateEnhanceParams(_ next: VideoEnhanceParams) {
        enhanceParams = next
        if !next.enabled {
            enhanceMode = .off
        } else if enhanceMode == .off {
            enhanceMode = .enhanced
        }
        enhancementBox.update(next)
        syncEnhancementPipeline()
    }

    public func cycleEnhanceMode() {
        let all = VideoEnhanceMode.allCases
        let idx = all.firstIndex(of: enhanceMode) ?? 0
        setEnhanceMode(all[(idx + 1) % all.count])
    }

    private func syncEnhancementPipeline() {
        guard let item = player.currentItem else { return }
        if !enhanceParams.enabled || enhanceMode == .off {
            item.videoComposition = nil
            return
        }
        if let comp = enhancementComposition {
            if item.videoComposition !== comp {
                item.videoComposition = comp
            }
            return
        }
        guard let asset = currentAsset else { return }
        let gen = loadGeneration
        Task {
            guard gen == self.loadGeneration, let liveItem = self.player.currentItem else { return }
            await self.attachEnhancementComposition(to: liveItem, asset: asset)
        }
    }

    private func attachEnhancementComposition(to playerItem: AVPlayerItem, asset: AVURLAsset) async {
        let box = enhancementBox
        do {
            let comp = try await AVVideoComposition.videoComposition(with: asset) { request in
                let p = box.snapshot()
                let extent = request.sourceImage.extent
                guard p.enabled else {
                    request.finish(with: request.sourceImage, context: box.ciContext)
                    return
                }

                var img = request.sourceImage.clampedToExtent()

                // 1. GPU Noise Reduction (cleans H.264 / low-light CCTV grain)
                if p.denoise > 0.002 {
                    let nr = CIFilter.noiseReduction()
                    nr.inputImage = img
                    nr.noiseLevel = Float(p.denoise)
                    nr.sharpness = Float(min(0.8, 0.35 + p.sharpness * 0.25))
                    if let out = nr.outputImage { img = out }
                }

                // 2. Shadow Lift & Highlight Recovery (reveals faces/objects in dark CCTV scenes)
                if p.shadowLift > 0.01 {
                    let hs = CIFilter.highlightShadowAdjust()
                    hs.inputImage = img
                    hs.shadowAmount = Float(p.shadowLift)
                    hs.highlightAmount = 0.92
                    if let out = hs.outputImage { img = out }
                }

                // 3. Smart Unsharp Mask + Luminance Sharpening (text, faces, number plates)
                if p.sharpness > 0.05 {
                    let unsharp = CIFilter.unsharpMask()
                    unsharp.inputImage = img
                    unsharp.radius = Float(1.6 + min(1.0, p.sharpness * 0.5))
                    unsharp.intensity = Float(min(1.6, p.sharpness * 0.9))
                    if let out = unsharp.outputImage { img = out }

                    let lum = CIFilter.sharpenLuminance()
                    lum.inputImage = img
                    lum.sharpness = Float(min(0.85, p.sharpness * 0.38))
                    if let out = lum.outputImage { img = out }
                }

                // 4. Local Clarity Contrast & Natural Saturation
                if abs(p.contrast - 1.0) > 0.005 || abs(p.saturation - 1.0) > 0.005 {
                    let cc = CIFilter.colorControls()
                    cc.inputImage = img
                    cc.contrast = Float(p.contrast)
                    cc.saturation = Float(p.saturation)
                    if let out = cc.outputImage { img = out }
                }

                request.finish(with: img.cropped(to: extent), context: box.ciContext)
            }
            self.enhancementComposition = comp
            if self.enhanceMode != .off {
                playerItem.videoComposition = comp
            }
        } catch {
            // Gracefully fall back to native unfiltered playback if track cannot be composited
        }
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, min(duration > 0 ? duration : seconds, seconds))
        currentTime = clamped
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
        updateSubtitle(at: clamped)
        savePositionIfNeeded(force: true)
    }

    public func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    public func stepFrame(by count: Int) {
        pause()
        player.currentItem?.step(byCount: count)
    }

    public func promptLoadSubtitles() {
        let panel = NSOpenPanel()
        panel.title = "Load Subtitles (.srt or .vtt)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            subtitles = SubtitleParser.parse(url: url)
            updateSubtitle(at: currentTime)
        }
    }

    public func requestHoverPreview(at seconds: Double) {
        let t = max(0, min(duration, seconds))
        // 1) 0ms synchronous RAM lookup from pre-warmed filmstrip / exact bucket cache
        let (instant, isExact) = previewEngine.instantFrame(for: t)
        if let instant {
            hoverPreviewImage = instant
        }
        if isExact { return }

        // 2) Rapid live keyframe refinement on persistent warm VideoToolbox decoder
        let gen = loadGeneration
        previewEngine.requestExactFrame(at: t) { [weak self] img in
            Task { @MainActor in
                guard let self, self.loadGeneration == gen else { return }
                self.hoverPreviewImage = img
            }
        }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let sec = CMTimeGetSeconds(time)
            guard sec.isFinite else { return }
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = sec
                self.isPlaying = self.player.rate > 0
                self.updateSubtitle(at: sec)
                self.savePositionIfNeeded(force: false)
            }
        }
    }

    private func stopObserving() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    private func updateSubtitle(at sec: Double) {
        guard !subtitles.isEmpty else {
            activeSubtitleText = nil
            return
        }
        activeSubtitleText = subtitles.first(where: { sec >= $0.startTime && sec <= $0.endTime })?.text
    }

    private func savePositionIfNeeded(force: Bool) {
        guard let item = currentItem else { return }
        if force || abs(currentTime - lastSavedPosition) >= 5.0 {
            lastSavedPosition = currentTime
            libraryStore?.updatePlaybackPosition(for: item.id, position: currentTime, duration: duration)
        }
    }
}
