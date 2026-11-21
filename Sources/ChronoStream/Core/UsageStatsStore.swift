import AppKit
import Foundation
import Observation

public struct DailyUsageRecord: Codable, Hashable, Sendable {
    public var dateKey: String // yyyy-MM-dd
    public var appSeconds: Double
    public var videoWatchedSeconds: Double
    public var audioListenedSeconds: Double

    public init(dateKey: String, appSeconds: Double = 0, videoWatchedSeconds: Double = 0, audioListenedSeconds: Double = 0) {
        self.dateKey = dateKey
        self.appSeconds = appSeconds
        self.videoWatchedSeconds = videoWatchedSeconds
        self.audioListenedSeconds = audioListenedSeconds
    }
}

public struct DailyChartPoint: Identifiable, Sendable {
    public let id: String
    public let dayLabel: String
    public let appMinutes: Double
    public let videoMinutes: Double
    public let audioMinutes: Double
}

/// 100% local, offline-first usage & watch-time recorder persisted in Application Support.
@MainActor
@Observable
public final class UsageStatsStore {
    public static let shared = UsageStatsStore()

    public var records: [String: DailyUsageRecord] = [:]

    private var timer: Timer?
    private var ticksSinceSave: Int = 0
    private weak var videoController: VideoPlayerController?
    private weak var audioController: AudioPlayerController?

    private static let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ChronoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage_stats.json")
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private init() {
        load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.save()
            }
        }
    }

    public func startTracking(videoController: VideoPlayerController, audioController: AudioPlayerController) {
        self.videoController = videoController
        self.audioController = audioController
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordTick(deltaSeconds: 5.0)
            }
        }
    }

    private func recordTick(deltaSeconds: Double) {
        let key = Self.dayKeyFormatter.string(from: Date())
        var rec = records[key] ?? DailyUsageRecord(dateKey: key)
        var changed = false

        if NSApp.isActive {
            rec.appSeconds += deltaSeconds
            changed = true
        }
        if videoController?.isPlaying == true {
            rec.videoWatchedSeconds += deltaSeconds
            changed = true
        }
        if audioController?.isPlaying == true {
            rec.audioListenedSeconds += deltaSeconds
            changed = true
        }

        if changed {
            records[key] = rec
            ticksSinceSave += 1
            if ticksSinceSave >= 6 { // Persist every ~30s
                ticksSinceSave = 0
                save()
            }
        }
    }

    // MARK: - Aggregated Stats

    public var todayRecord: DailyUsageRecord {
        let key = Self.dayKeyFormatter.string(from: Date())
        return records[key] ?? DailyUsageRecord(dateKey: key)
    }

    public var allTimeAppSeconds: Double {
        records.values.reduce(0) { $0 + $1.appSeconds }
    }

    public var allTimeVideoSeconds: Double {
        records.values.reduce(0) { $0 + $1.videoWatchedSeconds }
    }

    public var allTimeAudioSeconds: Double {
        records.values.reduce(0) { $0 + $1.audioListenedSeconds }
    }

    public var last7DaysPoints: [DailyChartPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset -> DailyChartPoint? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayKeyFormatter.string(from: date)
            let rec = records[key] ?? DailyUsageRecord(dateKey: key)
            let label = offset == 0 ? "Today" : Self.shortDayFormatter.string(from: date)
            return DailyChartPoint(
                id: key,
                dayLabel: label,
                appMinutes: rec.appSeconds / 60.0,
                videoMinutes: rec.videoWatchedSeconds / 60.0,
                audioMinutes: rec.audioListenedSeconds / 60.0
            )
        }
    }

    public var weekAppSeconds: Double {
        last7DaysPoints.reduce(0) { $0 + $1.appMinutes * 60.0 }
    }

    public var weekVideoSeconds: Double {
        last7DaysPoints.reduce(0) { $0 + $1.videoMinutes * 60.0 }
    }

    public var weekAudioSeconds: Double {
        last7DaysPoints.reduce(0) { $0 + $1.audioMinutes * 60.0 }
    }

    public static func formatHoursMinutes(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60.0).rounded())
        if totalMinutes < 1 {
            let secs = Int(seconds.rounded())
            return secs > 0 ? "\(secs)s" : "0m"
        }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(m)m"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode([String: DailyUsageRecord].self, from: data) else {
            return
        }
        self.records = decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }
}
