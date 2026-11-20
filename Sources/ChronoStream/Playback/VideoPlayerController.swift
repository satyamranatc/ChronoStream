import AppKit
@preconcurrency import AVFoundation
import Foundation
import Observation

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
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            player.volume = volume
            player.isMuted = isMuted

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
        currentItem = nil
        isLoading = false
        statusMessage = nil
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
