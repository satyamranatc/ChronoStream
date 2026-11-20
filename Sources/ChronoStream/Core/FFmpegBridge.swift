import AppKit
import Foundation

/// Non-blocking, cancellation-safe FFmpeg bridge.
/// Never blocks Swift's cooperative thread pool with waitUntilExit(); uses terminationHandler + Process.terminate() on cancel.
public actor FFmpegBridge {
    public static let shared = FFmpegBridge()

    public let ffmpegPath: String?
    public let ffprobePath: String?
    private let remuxDir: URL
    private let maxRemuxBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB cap
    private var inFlightRemux: [String: Task<URL?, Never>] = [:]

    // Bounded concurrency for thumbnail extraction (max 3 concurrent ffmpeg processes)
    private static let thumbLimiter = DispatchSemaphore(value: 3)

    private init() {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let fm = FileManager.default
        self.ffmpegPath = candidates.map { "\($0)/ffmpeg" }.first { fm.isExecutableFile(atPath: $0) }
        self.ffprobePath = candidates.map { "\($0)/ffprobe" }.first { fm.isExecutableFile(atPath: $0) }

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.remuxDir = caches.appendingPathComponent("ChronoStream/Remux", isDirectory: true)
        try? fm.createDirectory(at: remuxDir, withIntermediateDirectories: true)
    }

    public var isAvailable: Bool { ffmpegPath != nil }

    /// Remuxes a non-AVFoundation video/audio container into a seekable, AVFoundation-compatible MP4/M4A.
    public func remuxForPlayback(sourceURL: URL, isAudioOnly: Bool = false) async -> URL? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = Int(((attrs?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        let key = Self.fnvHash("\(sourceURL.path)|\(size)|\(mtime)")
        let ext = isAudioOnly ? "m4a" : "mp4"
        let outURL = remuxDir.appendingPathComponent("\(key).\(ext)")

        if fm.fileExists(atPath: outURL.path),
           let outSize = (try? fm.attributesOfItem(atPath: outURL.path)[.size] as? Int64),
           outSize > 0 {
            return outURL
        }

        if let existing = inFlightRemux[key] {
            return await existing.value
        }

        let remuxDirectory = self.remuxDir
        let task = Task<URL?, Never> {
            let tmpURL = remuxDirectory.appendingPathComponent("\(key).part.\(ext)")
            try? FileManager.default.removeItem(at: tmpURL)

            let okCopy: Bool
            if isAudioOnly {
                okCopy = await Self.runProcessAsync(ffmpeg, args: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", sourceURL.path,
                    "-vn", "-c:a", "aac", "-b:a", "256k",
                    "-f", "ipod", tmpURL.path
                ])
            } else {
                let fast = await Self.runProcessAsync(ffmpeg, args: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", sourceURL.path,
                    "-c:v", "copy", "-c:a", "copy",
                    "-movflags", "+faststart", "-f", "mp4", tmpURL.path
                ])
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: tmpURL)
                    return nil
                }
                if fast {
                    okCopy = true
                } else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    okCopy = await Self.runProcessAsync(ffmpeg, args: [
                        "-hide_banner", "-loglevel", "error", "-y",
                        "-i", sourceURL.path,
                        "-c:v", "copy", "-c:a", "aac",
                        "-movflags", "+faststart", "-f", "mp4", tmpURL.path
                    ])
                }
            }

            if !Task.isCancelled, okCopy, FileManager.default.fileExists(atPath: tmpURL.path) {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.moveItem(at: tmpURL, to: outURL)
                return outURL
            }
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }

        inFlightRemux[key] = task
        let result = await task.value
        inFlightRemux[key] = nil
        if result != nil { pruneCache() }
        return result
    }

    /// Non-isolated, bounded-concurrency, cancellation-safe thumbnail extractor so scrolling 500+ DVR files never stalls.
    public nonisolated func extractThumbnail(for url: URL, at seconds: Double, width: Int = 320) async -> NSImage? {
        guard let ffmpeg = await self.ffmpegPath else { return nil }
        if Task.isCancelled { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                Self.thumbLimiter.wait()
                defer { Self.thumbLimiter.signal() }

                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = [
                    "-hide_banner", "-loglevel", "error",
                    "-ss", String(format: "%.2f", max(0, seconds)),
                    "-i", url.path,
                    "-frames:v", "1",
                    "-vf", "scale=\(width):-2",
                    "-q:v", "6",
                    "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1"
                ]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, !data.isEmpty, let img = NSImage(data: data) {
                        continuation.resume(returning: img)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func clearRemuxCache() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: remuxDir, includingPropertiesForKeys: nil) {
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    public func remuxCacheBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: remuxDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - Video Studio Operations (Non-Blocking Async)

    public func trimVideo(input: URL, startSeconds: Double, endSeconds: Double, lossless: Bool, output: URL) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        let dur = max(0.5, endSeconds - startSeconds)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", max(0, startSeconds)), "-i", input.path, "-t", String(format: "%.2f", dur)]
        if lossless {
            args += ["-c", "copy", "-movflags", "+faststart", output.path]
        } else {
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-movflags", "+faststart", output.path]
        }
        return await Self.runProcessAsync(ffmpeg, args: args) ? .success(output) : .failure(StudioError.processingFailed("Trim failed."))
    }

    public func cropAndTransformVideo(
        input: URL,
        cropLeft: Double,
        cropRight: Double,
        cropTop: Double,
        cropBottom: Double,
        rotationDegrees: Int,
        muteAudio: Bool,
        speed: Double,
        output: URL
    ) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        var vFilters: [String] = []
        let wFrac = max(0.1, 1.0 - cropLeft - cropRight)
        let hFrac = max(0.1, 1.0 - cropTop - cropBottom)
        if cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 {
            vFilters.append(String(format: "crop=trunc(iw*%.4f/2)*2:trunc(ih*%.4f/2)*2:trunc(iw*%.4f/2)*2:trunc(ih*%.4f/2)*2", wFrac, hFrac, cropLeft, cropTop))
        }
        switch ((rotationDegrees % 360) + 360) % 360 {
        case 90: vFilters.append("transpose=1")
        case 180: vFilters.append("transpose=1,transpose=1")
        case 270: vFilters.append("transpose=2")
        default: break
        }
        if abs(speed - 1.0) > 0.01 {
            vFilters.append(String(format: "setpts=%.4f*PTS", 1.0 / speed))
        }

        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
        if !vFilters.isEmpty { args += ["-vf", vFilters.joined(separator: ",")] }
        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
        if muteAudio {
            args += ["-an"]
        } else if abs(speed - 1.0) > 0.01 {
            args += ["-af", String(format: "atempo=%.3f", max(0.5, min(2.0, speed))), "-c:a", "aac"]
        } else {
            args += ["-c:a", "aac"]
        }
        args += ["-movflags", "+faststart", output.path]
        return await Self.runProcessAsync(ffmpeg, args: args) ? .success(output) : .failure(StudioError.processingFailed("Video transform failed."))
    }

    public func mergeTwoVideos(first: URL, second: URL, output: URL) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        let listURL = FileManager.default.temporaryDirectory.appendingPathComponent("cs_concat_\(UUID().uuidString).txt")
        let escaped1 = first.path.replacingOccurrences(of: "'", with: "'\\''")
        let escaped2 = second.path.replacingOccurrences(of: "'", with: "'\\''")
        try? "file '\(escaped1)'\nfile '\(escaped2)'\n".write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }

        if await Self.runProcessAsync(ffmpeg, args: ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", "-movflags", "+faststart", output.path]) {
            return .success(output)
        }
        let filter = "[0:v]scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1[v0];[1:v]scale=iw:ih:force_original_aspect_ratio=decrease,setsar=1[v1];[v0][v1]concat=n=2:v=1:a=0[v]"
        if await Self.runProcessAsync(ffmpeg, args: ["-hide_banner", "-loglevel", "error", "-y", "-i", first.path, "-i", second.path, "-filter_complex", filter, "-map", "[v]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-movflags", "+faststart", output.path]) {
            return .success(output)
        }
        return .failure(StudioError.processingFailed("Could not merge the two videos."))
    }

    public func replaceAudio(video: URL, audio: URL, output: URL) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        let args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", video.path, "-i", audio.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-shortest", "-movflags", "+faststart", output.path
        ]
        return await Self.runProcessAsync(ffmpeg, args: args) ? .success(output) : .failure(StudioError.processingFailed("Replacing audio failed."))
    }

    public func extractAudio(video: URL, format: String, output: URL) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        let codecArgs = format.lowercased() == "mp3" ? ["-c:a", "libmp3lame", "-q:a", "2"] : ["-c:a", "aac", "-b:a", "256k"]
        let args = ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-vn"] + codecArgs + [output.path]
        return await Self.runProcessAsync(ffmpeg, args: args) ? .success(output) : .failure(StudioError.processingFailed("Audio extraction failed."))
    }

    public func createGifFromVideo(video: URL, startSeconds: Double, durationSeconds: Double, fps: Int, width: Int, output: URL) async -> Result<URL, Error> {
        guard let ffmpeg = ffmpegPath else { return .failure(StudioError.ffmpegMissing) }
        let vf = "fps=\(max(4, min(24, fps))),scale=\(max(240, min(960, width))):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
        let args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-ss", String(format: "%.2f", max(0, startSeconds)),
            "-t", String(format: "%.2f", max(0.5, min(20, durationSeconds))),
            "-i", video.path, "-vf", vf, output.path
        ]
        return await Self.runProcessAsync(ffmpeg, args: args) ? .success(output) : .failure(StudioError.processingFailed("GIF export failed."))
    }

    public enum StudioError: LocalizedError {
        case ffmpegMissing
        case processingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .ffmpegMissing: return "FFmpeg is required. Install it via Homebrew (brew install ffmpeg)."
            case .processingFailed(let msg): return msg
            }
        }
    }

    private func pruneCache() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: remuxDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = urls.compactMap { u -> (URL, Int64, Date)? in
            guard let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let sz = vals.fileSize else { return nil }
            return (u, Int64(sz), vals.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }

        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for e in entries {
            if total <= maxRemuxBytes { break }
            try? fm.removeItem(at: e.0)
            total -= e.1
        }
    }

    /// Non-blocking async process runner that kills the subprocess immediately if the Swift Task is cancelled.
    private nonisolated static func runProcessAsync(_ path: String, args: [String]) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                proc.terminationHandler = { p in
                    cont.resume(returning: p.terminationStatus == 0)
                }
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: false)
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    private nonisolated static func fnvHash(_ s: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h ^= UInt64(b); h &*= 10995981039346656037 &+ 1099511628211 }
        return String(format: "%016llx", h)
    }
}
