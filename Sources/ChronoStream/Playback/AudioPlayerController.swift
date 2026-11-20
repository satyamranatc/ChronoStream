import AppKit
import AVFoundation
import Foundation
import Observation

public enum AudioRepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    public var next: AudioRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    public var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

@MainActor
@Observable
public final class AudioPlayerController {
    public let player = AVPlayer()
    public var currentItem: MediaItem?
    public var queue: [MediaItem] = []
    public var trackTitle: String = ""
    public var trackArtist: String = ""
    public var trackAlbum: String = ""
    public var artwork: NSImage?

    public var isPlaying: Bool = false
    public var isLoading: Bool = false
    public var errorMessage: String?

    public var currentTime: Double = 0
    public var duration: Double = 0
    public var volume: Float = 0.85 {
        didSet { player.volume = volume }
    }
    public var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    public var playbackRate: Float = 1.0 {
        didSet { if isPlaying { player.rate = playbackRate } }
    }
    public var isShuffled: Bool = false
    public var repeatMode: AudioRepeatMode = .all
    public var sleepTimerSecondsRemaining: Int?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var loadGeneration: Int = 0
    private weak var libraryStore: LibraryStore?

    public init() {}

    public func bind(store: LibraryStore) {
        self.libraryStore = store
    }

    public func play(_ item: MediaItem, inQueue newQueue: [MediaItem]) {
        let audioOnly = newQueue.filter { $0.kind == .audio }
        self.queue = audioOnly.isEmpty ? [item] : audioOnly
        loadTrack(item)
    }

    public func loadTrack(_ item: MediaItem) {
        loadGeneration += 1
        let gen = loadGeneration
        loadTask?.cancel()
        stopObserving()
        player.pause()

        currentItem = item
        trackTitle = item.url.deletingPathExtension().lastPathComponent
        trackArtist = item.fileExtension
        trackAlbum = ""
        artwork = nil
        isLoading = true
        errorMessage = nil
        currentTime = 0
        duration = item.duration ?? 0

        loadTask = Task {
            let compat = await Task.detached(priority: .userInitiated) {
                MediaFormatRegistry.inspectCompatibility(for: item.url)
            }.value
            guard !Task.isCancelled, gen == self.loadGeneration else { return }

            let playURL: URL
            if compat == .ffmpegRemux {
                if let remuxed = await FFmpegBridge.shared.remuxForPlayback(sourceURL: item.url, isAudioOnly: true) {
                    guard !Task.isCancelled, gen == self.loadGeneration else { return }
                    playURL = remuxed
                } else {
                    guard !Task.isCancelled, gen == self.loadGeneration else { return }
                    isLoading = false
                    errorMessage = "Could not decode \(item.fileExtension) audio."
                    return
                }
            } else {
                playURL = item.url
            }

            let asset = AVURLAsset(url: playURL)
            if let dur = try? await asset.load(.duration) {
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                let sec = CMTimeGetSeconds(dur)
                self.duration = sec.isFinite && sec > 0 ? sec : 0
            }
            if let meta = try? await asset.load(.commonMetadata) {
                for m in meta {
                    guard !Task.isCancelled, gen == self.loadGeneration else { return }
                    if m.commonKey == .commonKeyTitle, let v = try? await m.load(.stringValue), !v.isEmpty {
                        self.trackTitle = v
                    } else if m.commonKey == .commonKeyArtist, let v = try? await m.load(.stringValue), !v.isEmpty {
                        self.trackArtist = v
                    } else if m.commonKey == .commonKeyAlbumName, let v = try? await m.load(.stringValue), !v.isEmpty {
                        self.trackAlbum = v
                    } else if m.commonKey == .commonKeyArtwork, let data = try? await m.load(.dataValue), let img = NSImage(data: data) {
                        self.artwork = img
                    }
                }
            }

            guard !Task.isCancelled, gen == self.loadGeneration else { return }
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            player.volume = volume
            player.isMuted = isMuted

            if item.lastPosition > 5 && (self.duration == 0 || item.lastPosition < self.duration - 5) {
                await player.seek(to: CMTime(seconds: item.lastPosition, preferredTimescale: 600))
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                self.currentTime = item.lastPosition
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleTrackEnded()
                }
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
        if let item = currentItem {
            libraryStore?.updatePlaybackPosition(for: item.id, position: currentTime, duration: duration)
        }
    }

    public func stop() {
        loadGeneration += 1
        loadTask?.cancel()
        cancelSleepTimer()
        pause()
        stopObserving()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, min(duration > 0 ? duration : seconds, seconds))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    public func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    public func playNext() {
        guard !queue.isEmpty else { return }
        if isShuffled, let random = queue.randomElement() {
            loadTrack(random)
            return
        }
        guard let cur = currentItem, let idx = queue.firstIndex(where: { $0.id == cur.id }) else {
            loadTrack(queue[0])
            return
        }
        let nextIdx = idx + 1
        if nextIdx < queue.count {
            loadTrack(queue[nextIdx])
        } else if repeatMode == .all {
            loadTrack(queue[0])
        } else {
            pause()
        }
    }

    public func playPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty, let cur = currentItem, let idx = queue.firstIndex(where: { $0.id == cur.id }) else { return }
        let prevIdx = (idx - 1 + queue.count) % queue.count
        loadTrack(queue[prevIdx])
    }

    public func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        sleepTimerSecondsRemaining = minutes * 60
        sleepTask = Task {
            while let rem = sleepTimerSecondsRemaining, rem > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                if let cur = sleepTimerSecondsRemaining {
                    if cur <= 1 {
                        sleepTimerSecondsRemaining = nil
                        pause()
                        break
                    } else {
                        sleepTimerSecondsRemaining = cur - 1
                    }
                }
            }
        }
    }

    public func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerSecondsRemaining = nil
    }

    private func handleTrackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            play()
        case .all, .off:
            playNext()
        }
    }

    private func startObserving() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main) { [weak self] time in
            let sec = CMTimeGetSeconds(time)
            guard sec.isFinite else { return }
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = sec
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    private func stopObserving() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let end = endObserver {
            NotificationCenter.default.removeObserver(end)
            endObserver = nil
        }
    }
}
