import AppKit
import Charts
import Foundation
import Observation
import SwiftUI

private enum DashboardTab: String, CaseIterable, Identifiable {
    case stats = "Stats & Activity"
    case explore = "Explore Today"
    var id: String { rawValue }
}

public struct DashboardWeather: Sendable {
    public let temperatureC: Double
    public let windKmh: Double
    public let condition: String
    public let symbol: String
}

public struct DashboardFeaturedPhoto: Sendable {
    public let title: String
    public let description: String
    public let imageURL: URL?
}

public struct DashboardQuote: Sendable {
    public let quote: String
    public let author: String
}

@MainActor
@Observable
public final class DashboardFeedModel {
    public var weather: DashboardWeather?
    public var featuredPhoto: DashboardFeaturedPhoto?
    public var featuredNSImage: NSImage?
    public var onThisDay: String?
    public var quote: DashboardQuote?
    public var isLoading: Bool = false
    public var lastUpdated: Date?

    public init() {}

    public func refreshAll() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            async let w = Self.fetchWeather()
            async let q = Self.fetchQuote()
            async let wiki = Self.fetchWikimediaFeatured()

            let (weatherRes, quoteRes, wikiRes) = await (w, q, wiki)
            self.weather = weatherRes
            self.quote = quoteRes
            self.featuredPhoto = wikiRes.photo
            self.onThisDay = wikiRes.onThisDay
            self.lastUpdated = Date()
            self.isLoading = false

            if let imgURL = wikiRes.photo?.imageURL {
                let img = await Self.fetchImage(url: imgURL)
                self.featuredNSImage = img
            }
        }
    }

    public func refreshQuoteOnly() {
        Task {
            if let q = await Self.fetchQuote() {
                self.quote = q
            }
        }
    }

    private nonisolated static func fetchWeather() async -> DashboardWeather? {
        // Open-Meteo (100% free, zero API key) — defaults to Indore, MP
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=22.7196&longitude=75.8577&current=temperature_2m,weather_code,wind_speed_10m") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = json["current"] as? [String: Any],
              let temp = cur["temperature_2m"] as? Double else { return nil }
        let wind = (cur["wind_speed_10m"] as? Double) ?? 0
        let code = (cur["weather_code"] as? Int) ?? 0
        let (cond, sym) = weatherDescription(code: code)
        return DashboardWeather(temperatureC: temp, windKmh: wind, condition: cond, symbol: sym)
    }

    private nonisolated static func weatherDescription(code: Int) -> (String, String) {
        switch code {
        case 0: return ("Clear", "sun.max.fill")
        case 1, 2: return ("Partly Cloudy", "cloud.sun.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Foggy", "cloud.fog.fill")
        case 51...67: return ("Rain", "cloud.rain.fill")
        case 71...77: return ("Snow", "cloud.snow.fill")
        case 80...82: return ("Showers", "cloud.heavyrain.fill")
        case 95...99: return ("Thunderstorm", "cloud.bolt.rain.fill")
        default: return ("Calm", "cloud.sun.fill")
        }
    }

    private nonisolated static func fetchQuote() async -> DashboardQuote? {
        guard let url = URL(string: "https://dummyjson.com/quotes/random") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = json["quote"] as? String,
              let a = json["author"] as? String else { return nil }
        return DashboardQuote(quote: q, author: a)
    }

    private nonisolated static func fetchWikimediaFeatured() async -> (photo: DashboardFeaturedPhoto?, onThisDay: String?) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let y = comps.year ?? 2026
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/feed/featured/\(y)/\(m)/\(d)") else {
            return (nil, nil)
        }
        var req = URLRequest(url: url)
        req.setValue("ChronoStream/2.0 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        var photo: DashboardFeaturedPhoto?
        if let imgDict = json["image"] as? [String: Any] {
            let descDict = imgDict["description"] as? [String: Any]
            let desc = (descDict?["text"] as? String) ?? "Featured Wikimedia photograph of the day."
            let title = (imgDict["title"] as? String)?.replacingOccurrences(of: "File:", with: "") ?? "Picture of the Day"
            let thumbDict = imgDict["thumbnail"] as? [String: Any]
            let srcStr = (thumbDict?["source"] as? String) ?? ((imgDict["image"] as? [String: Any])?["source"] as? String)
            photo = DashboardFeaturedPhoto(title: title, description: desc, imageURL: srcStr.flatMap(URL.init(string:)))
        }

        var historyLine: String?
        if let otd = json["onthisday"] as? [[String: Any]], let first = otd.first,
           let text = first["text"] as? String {
            if let yr = first["year"] as? Int {
                historyLine = "\(yr) — \(text)"
            } else {
                historyLine = text
            }
        }
        return (photo, historyLine)
    }

    private nonisolated static func fetchImage(url: URL) async -> NSImage? {
        var req = URLRequest(url: url)
        req.setValue("ChronoStream/2.0 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return NSImage(data: data)
    }
}

/// Smooth GPU-composited living wave banner for the Dashboard hero.
private struct AmbientWaveCanvas: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for layer in 0..<3 {
                    let phase = t * (0.65 + Double(layer) * 0.25) + Double(layer) * 1.4
                    let amp = 10.0 + Double(layer) * 5.0
                    let baseY = size.height * (0.58 + Double(layer) * 0.1)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for x in stride(from: 0.0, through: Double(size.width), by: 8.0) {
                        let norm = x / max(1.0, Double(size.width))
                        let y = baseY + sin(norm * .pi * 2.4 + phase) * amp
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()

                    let opacity = 0.08 - Double(layer) * 0.02
                    ctx.fill(path, with: .color(Color(red: 0.0, green: 0.478, blue: 1.0).opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

public struct DashboardView: View {
    @Bindable var store: LibraryStore
    @State private var feed = DashboardFeedModel()
    @State private var appeared = false
    @State private var activeTab: DashboardTab = .stats
    @Environment(\.colorScheme) private var colorScheme
    private let usage = UsageStatsStore.shared

    private var canvasBackground: Color {
        colorScheme == .light ? Color(red: 0.962, green: 0.970, blue: 0.980) : Color(nsColor: .windowBackgroundColor)
    }

    private var cardSurface: Color {
        colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        colorScheme == .light ? Color.black.opacity(0.06) : Color.primary.opacity(0.08)
    }

    private var cardShadow: Color {
        colorScheme == .light ? Color.black.opacity(0.045) : Color.clear
    }

    public init(store: LibraryStore) {
        self.store = store
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default: return "Late Night Studio"
        }
    }

    private var totalBytes: Int64 {
        store.items.reduce(0) { $0 + $1.fileSize }
    }

    private func bytes(for kind: MediaKind) -> Int64 {
        store.items.filter { $0.kind == kind }.reduce(0) { $0 + $1.fileSize }
    }

    private var continueItems: [MediaItem] {
        store.items
            .filter { ($0.kind == .video || $0.kind == .audio) && $0.lastPosition > 5 }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroBanner

                // Clean Apple-style 2-Tab Switcher: Stats & Activity vs Explore Today
                HStack {
                    Picker("", selection: $activeTab) {
                        ForEach(DashboardTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    Spacer()

                    if activeTab == .stats {
                        HStack(spacing: 10) {
                            Text("Recorded locally · 100% private")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if usage.allTimeAppSeconds > 0 {
                                Button("Reset") {
                                    usage.resetAll()
                                }
                                .buttonStyle(.plain)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .help("Clear all locally recorded activity stats")
                            }
                        }
                    } else {
                        Text("Live Feed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if activeTab == .stats {
                    watchTimeKPIRow
                    activityChartsRow
                    statsGrid
                    storageBreakdownCard

                    if !continueItems.isEmpty {
                        continueWatchingStrip
                    }
                } else {
                    liveInternetSection
                }
            }
            .padding(24)
        }
        .background(canvasBackground)
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    feed.refreshAll()
                } label: {
                    Label("Refresh Feed", systemImage: "arrow.clockwise")
                }
                .disabled(feed.isLoading)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                appeared = true
            }
            if feed.lastUpdated == nil {
                feed.refreshAll()
            }
        }
    }

    // MARK: - Animated Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardSurface)
                .shadow(color: cardShadow, radius: 14, y: 5)
                .overlay(
                    AmbientWaveCanvas()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(cardBorder, lineWidth: 1)
                )

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)

                        if let w = feed.weather {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Label("\(Int(w.temperatureC.rounded()))°C \(w.condition)", systemImage: w.symbol)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(greeting)
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("\(store.items.count) media items indexed across \(store.folders.count) authorized folder\(store.folders.count == 1 ? "" : "s") · \(MediaFormatting.byteString(totalBytes)) total")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            store.promptOpenFiles()
                        } label: {
                            Label("Open Media", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            store.promptAddFolder()
                        } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            store.selection = .documentStudio
                        } label: {
                            Label("Doc Writer", systemImage: "doc.text.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            store.selection = .photoStudio
                        } label: {
                            Label("Photo Studio", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            store.selection = .videoStudio
                        } label: {
                            Label("Video Studio", systemImage: "scissors")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(22)
        }
        .frame(minHeight: 162)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
    }

    // MARK: - Usage & Watch-Time KPIs + Native Apple Charts

    private let brandTeal = Color(red: 0.0, green: 0.478, blue: 1.0)      // Apple Blue #007AFF
    private let deepTeal = Color(red: 0.0, green: 0.318, blue: 0.835)     // Deep Apple Blue #0051D5
    private let midTeal = Color(red: 0.188, green: 0.690, blue: 0.780)    // Subtle Apple Teal #30B0C7
    private let softTeal = Color(red: 0.35, green: 0.65, blue: 0.98)      // Soft Sky Blue
    private let mistTeal = Color(red: 0.72, green: 0.86, blue: 0.98)      // Mist Blue

    private var watchTimeKPIRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            usageKPICard(
                title: "Time in ChronoStream",
                todayValue: UsageStatsStore.formatHoursMinutes(usage.todayRecord.appSeconds),
                weekValue: UsageStatsStore.formatHoursMinutes(usage.weekAppSeconds),
                allTimeValue: UsageStatsStore.formatHoursMinutes(usage.allTimeAppSeconds),
                symbol: "clock.fill",
                tint: brandTeal
            )
            usageKPICard(
                title: "Video Watched",
                todayValue: UsageStatsStore.formatHoursMinutes(usage.todayRecord.videoWatchedSeconds),
                weekValue: UsageStatsStore.formatHoursMinutes(usage.weekVideoSeconds),
                allTimeValue: UsageStatsStore.formatHoursMinutes(usage.allTimeVideoSeconds),
                symbol: "play.rectangle.fill",
                tint: deepTeal
            )
            usageKPICard(
                title: "Audio Listened",
                todayValue: UsageStatsStore.formatHoursMinutes(usage.todayRecord.audioListenedSeconds),
                weekValue: UsageStatsStore.formatHoursMinutes(usage.weekAudioSeconds),
                allTimeValue: UsageStatsStore.formatHoursMinutes(usage.allTimeAudioSeconds),
                symbol: "headphones",
                tint: midTeal
            )
        }
    }

    private func usageKPICard(title: String, todayValue: String, weekValue: String, allTimeValue: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Text("Today")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }

            Text(todayValue)
                .font(.title.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())

            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("7d: \(weekValue) · All: \(allTimeValue)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
        .shadow(color: cardShadow, radius: 10, y: 3)
    }

    private var activityChartsRow: some View {
        let points = usage.last7DaysPoints
        let videoMins = usage.weekVideoSeconds / 60.0
        let audioMins = usage.weekAudioSeconds / 60.0
        let browseMins = max(0, (usage.weekAppSeconds - usage.weekVideoSeconds - usage.weekAudioSeconds) / 60.0)
        let totalWeekMins = max(0.01, videoMins + audioMins + browseMins)

        let slices: [(label: String, value: Double, color: Color)] = [
            ("Video Watched", videoMins, brandTeal),
            ("Audio Listened", audioMins, midTeal),
            ("Library & Studio", browseMins, mistTeal)
        ]

        return HStack(alignment: .top, spacing: 14) {
            // Graph 1: 7-Day Activity Bar Chart (Apple Screen Time style)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("7-Day Activity")
                            .font(.subheadline.weight(.semibold))
                        Text("Minutes spent in app vs. video watched")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        legendDot("In App", color: mistTeal)
                        legendDot("Watched", color: brandTeal)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Chart(points) { pt in
                    let nonWatchMins = max(0, pt.appMinutes - pt.videoMinutes)
                    BarMark(
                        x: .value("Day", pt.dayLabel),
                        y: .value("Minutes", pt.videoMinutes)
                    )
                    .foregroundStyle(brandTeal.gradient)
                    .cornerRadius(4)

                    BarMark(
                        x: .value("Day", pt.dayLabel),
                        y: .value("Minutes", nonWatchMins)
                    )
                    .foregroundStyle(mistTeal)
                    .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { val in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Color.primary.opacity(0.1))
                        AxisValueLabel {
                            if let m = val.as(Double.self) {
                                Text("\(Int(m))m")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: 175)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
            .shadow(color: cardShadow, radius: 10, y: 3)

            // Graph 2: Weekly Time Breakdown Donut Chart
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time Breakdown")
                        .font(.subheadline.weight(.semibold))
                    Text("Last 7 days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ZStack {
                    let activeSlices = slices.filter { $0.value > 0 }
                    if activeSlices.isEmpty {
                        Circle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 20)
                            .frame(width: 112, height: 112)
                            .frame(height: 140)
                    } else {
                        Chart(activeSlices, id: \.label) { s in
                            SectorMark(
                                angle: .value("Minutes", s.value),
                                innerRadius: .ratio(0.64),
                                angularInset: activeSlices.count > 1 ? 2 : 0
                            )
                            .cornerRadius(4)
                            .foregroundStyle(s.color.gradient)
                        }
                        .frame(height: 140)
                    }

                    VStack(spacing: 1) {
                        Text(UsageStatsStore.formatHoursMinutes(usage.weekAppSeconds))
                            .font(.callout.weight(.bold).monospacedDigit())
                        Text("7d total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 5) {
                    ForEach(slices, id: \.label) { s in
                        HStack(spacing: 6) {
                            Circle().fill(s.color).frame(width: 7, height: 7)
                            Text(s.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(usage.weekAppSeconds > 0 ? Int(((s.value / totalWeekMins) * 100).rounded()) : 0)%")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 245, alignment: .leading)
            .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
            .shadow(color: cardShadow, radius: 10, y: 3)
        }
    }

    // MARK: - Live Library Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 14)], spacing: 14) {
            statCard(title: "Videos", count: store.count(for: .videos), size: bytes(for: .video), symbol: "film", tint: brandTeal) {
                store.selection = .smart(.videos)
            }
            statCard(title: "Music & Audio", count: store.count(for: .audio), size: bytes(for: .audio), symbol: "music.note", tint: deepTeal) {
                store.selection = .smart(.audio)
            }
            statCard(title: "Photos", count: store.count(for: .photos), size: bytes(for: .image), symbol: "photo", tint: midTeal) {
                store.selection = .smart(.photos)
            }
            statCard(title: "PDF Documents", count: store.count(for: .documents), size: bytes(for: .pdf), symbol: "doc.richtext", tint: softTeal) {
                store.selection = .smart(.documents)
            }
        }
    }

    private func statCard(title: String, count: Int, size: Int64, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("\(count)")
                    .font(.title.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())

                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(MediaFormatting.byteString(size))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: 1)
            )
            .shadow(color: cardShadow, radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Animated Storage Breakdown Bar

    private var storageBreakdownCard: some View {
        let total = max(Int64(1), totalBytes)
        let vFrac = Double(bytes(for: .video)) / Double(total)
        let aFrac = Double(bytes(for: .audio)) / Double(total)
        let pFrac = Double(bytes(for: .image)) / Double(total)
        let dFrac = Double(bytes(for: .pdf)) / Double(total)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library Storage Breakdown")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !store.duplicateItemIDs.isEmpty {
                    Button {
                        store.selection = .smart(.duplicates)
                    } label: {
                        Label("\(store.duplicateItemIDs.count) duplicates detected", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Text(MediaFormatting.byteString(totalBytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                HStack(spacing: 2) {
                    if vFrac > 0 { RoundedRectangle(cornerRadius: 4).fill(brandTeal).frame(width: max(4, w * vFrac)) }
                    if aFrac > 0 { RoundedRectangle(cornerRadius: 4).fill(deepTeal).frame(width: max(4, w * aFrac)) }
                    if pFrac > 0 { RoundedRectangle(cornerRadius: 4).fill(midTeal).frame(width: max(4, w * pFrac)) }
                    if dFrac > 0 { RoundedRectangle(cornerRadius: 4).fill(mistTeal).frame(width: max(4, w * dFrac)) }
                    if totalBytes == 0 { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)) }
                }
                .animation(.easeInOut(duration: 0.45), value: totalBytes)
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                legendDot("Videos", color: brandTeal)
                legendDot("Audio", color: deepTeal)
                legendDot("Photos", color: midTeal)
                legendDot("PDFs", color: mistTeal)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func legendDot(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // MARK: - Continue Watching Strip

    private var continueWatchingStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching & Listening")
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(continueItems.prefix(8)) { item in
                        Button {
                            store.openItem(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: item.kind.systemImage)
                                        .foregroundStyle(Color.accentColor)
                                    Text("Resume \(MediaFormatting.timeString(item.lastPosition))")
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(item.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(MediaFormatting.byteString(item.fileSize))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(width: 210, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Free Live Internet Cards (Wikimedia Picture of the Day + History + Daily Reflection)

    private var liveInternetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explore Today")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Live Feed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 14) {
                // Wikimedia Picture of the Day
                VStack(alignment: .leading, spacing: 10) {
                    Text("Picture of the Day")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    if let img = feed.featuredNSImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 170)
                            .overlay {
                                if feed.isLoading {
                                    ProgressView()
                                } else {
                                    Label("Connect to Wi-Fi to load", systemImage: "photo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }

                    if let photo = feed.featuredPhoto {
                        Text(photo.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                .shadow(color: cardShadow, radius: 10, y: 3)

                // Right Column: Daily Reflection + On This Day
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Daily Reflection")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Button {
                                feed.refreshQuoteOnly()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("New Quote")
                        }

                        if let q = feed.quote {
                            Text("“\(q.quote)”")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("— \(q.author)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Loading reflection…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                    .shadow(color: cardShadow, radius: 10, y: 3)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("On This Day in History")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(feed.onThisDay ?? "Connect to internet to view today's historical highlight.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardBorder, lineWidth: 1))
                    .shadow(color: cardShadow, radius: 10, y: 3)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
