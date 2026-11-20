import AppKit
import SwiftUI

/// Smooth 28-bar reactive spectrum visualizer (pauses cleanly when audio is paused).
private struct AudioSpectrumCanvas: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let barCount = 28
                let spacing: CGFloat = 4
                let barW = max(2, (size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))

                for i in 0..<barCount {
                    let norm = Double(i) / Double(barCount - 1)
                    let bell = sin(norm * .pi)
                    let wave = isPlaying
                        ? (0.28 + 0.72 * abs(sin(t * 3.4 + Double(i) * 0.55) * cos(t * 1.9 - Double(i) * 0.3))) * bell
                        : 0.14
                    let h = max(3, CGFloat(wave) * size.height)
                    let x = CGFloat(i) * (barW + spacing)
                    let y = (size.height - h) / 2.0
                    let rect = CGRect(x: x, y: y, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                    ctx.fill(path, with: .color(isPlaying ? Color.accentColor.opacity(0.65 + 0.35 * bell) : Color.primary.opacity(0.16)))
                }
            }
        }
    }
}

/// Studio-grade native macOS Music Player with ambient artwork glow, live spectrum visualizer,
/// draggable scrubber, sleep timer, speed control, and a searchable Up Next queue.
public struct AudioStageView: View {
    @Bindable var controller: AudioPlayerController
    let item: MediaItem
    let queue: [MediaItem]
    let onSelectTrack: (MediaItem) -> Void
    let onShare: () -> Void
    let onClose: () -> Void

    @State private var queueFilter: String = ""
    @State private var isDraggingScrubber: Bool = false
    @State private var dragSeconds: Double = 0
    @State private var barPhase = false

    public init(
        controller: AudioPlayerController,
        item: MediaItem,
        queue: [MediaItem],
        onSelectTrack: @escaping (MediaItem) -> Void,
        onShare: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.item = item
        self.queue = queue
        self.onSelectTrack = onSelectTrack
        self.onShare = onShare
        self.onClose = onClose
    }

    private var filteredQueue: [MediaItem] {
        let q = queueFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return controller.queue }
        return controller.queue.filter { $0.name.lowercased().contains(q) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isPlaying ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(controller.isPlaying ? "Now Playing" : "Paused")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    // Sleep Timer menu
                    Menu {
                        Button("Off") { controller.cancelSleepTimer() }
                        Divider()
                        Button("15 Minutes") { controller.startSleepTimer(minutes: 15) }
                        Button("30 Minutes") { controller.startSleepTimer(minutes: 30) }
                        Button("60 Minutes") { controller.startSleepTimer(minutes: 60) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.zzz")
                            if let rem = controller.sleepTimerSecondsRemaining {
                                Text(MediaFormatting.timeString(Double(rem)))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .foregroundStyle(controller.sleepTimerSecondsRemaining != nil ? Color.accentColor : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sleep Timer")

                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Share via AirDrop or Wi-Fi QR")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Two-column studio layout (Now Playing Stage + Up Next Queue)
            HSplitView {
                nowPlayingStage
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                queueSidebar
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380, maxHeight: .infinity)
            }
        }
        .onAppear {
            if controller.currentItem?.id != item.id {
                controller.play(item, inQueue: queue)
            }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                barPhase.toggle()
            }
        }
        .onChange(of: item.id) { _, _ in
            if controller.currentItem?.id != item.id {
                controller.play(item, inQueue: queue)
            }
        }
    }

    // MARK: - Left Column: Frosted Now Playing Stage

    private var nowPlayingStage: some View {
        ZStack {
            // Subtle ambient artwork glow backdrop
            if let art = controller.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 72)
                    .opacity(0.18)
                    .ignoresSafeArea()
            } else {
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.12), Color(nsColor: .windowBackgroundColor)],
                    center: .top,
                    startRadius: 20,
                    endRadius: 480
                )
            }

            VStack(spacing: 22) {
                // Album Artwork (scales gently with play state like Apple Music)
                artworkView
                    .frame(width: 190, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(controller.isPlaying ? 0.24 : 0.12), radius: controller.isPlaying ? 22 : 10, y: 8)
                    .scaleEffect(controller.isPlaying ? 1.0 : 0.93)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: controller.isPlaying)

                // Track Info
                VStack(spacing: 4) {
                    Text(controller.trackTitle.isEmpty ? item.name : controller.trackTitle)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(controller.trackAlbum.isEmpty ? controller.trackArtist : "\(controller.trackArtist) · \(controller.trackAlbum)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(item.fileExtension) · \(MediaFormatting.byteString(item.fileSize))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)

                // Live Spectrum Visualizer
                AudioSpectrumCanvas(isPlaying: controller.isPlaying)
                    .frame(width: 280, height: 28)

                // Draggable Scrubber
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        let dur = max(0.001, controller.duration)
                        let shown = isDraggingScrubber ? dragSeconds : controller.currentTime
                        let pct = min(1, max(0, shown / dur))

                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 5)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: w * pct, height: 5)
                            Circle()
                                .fill(Color.white)
                                .shadow(radius: 2)
                                .frame(width: 13, height: 13)
                                .offset(x: max(0, min(w - 13, w * pct - 6.5)))
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    isDraggingScrubber = true
                                    dragSeconds = min(1, max(0, val.location.x / w)) * dur
                                }
                                .onEnded { val in
                                    let target = min(1, max(0, val.location.x / w)) * dur
                                    isDraggingScrubber = false
                                    controller.seek(to: target)
                                }
                        )
                    }
                    .frame(height: 16)

                    HStack {
                        Text(MediaFormatting.timeString(isDraggingScrubber ? dragSeconds : controller.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("-\(MediaFormatting.timeString(max(0, controller.duration - (isDraggingScrubber ? dragSeconds : controller.currentTime))))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 400)

                // Transport Controls
                HStack(spacing: 24) {
                    Button { controller.isShuffled.toggle() } label: {
                        Image(systemName: "shuffle")
                            .font(.callout)
                            .foregroundStyle(controller.isShuffled ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button { controller.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button { controller.playPrevious() } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Button { controller.togglePlayPause() } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 60, height: 60)
                                .shadow(color: Color.accentColor.opacity(0.32), radius: 12, y: 4)
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                                .offset(x: controller.isPlaying ? 0 : 1.5)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { controller.playNext() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Button { controller.skip(by: 15) } label: {
                        Image(systemName: "goforward.15")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button { controller.repeatMode = controller.repeatMode.next } label: {
                        Image(systemName: controller.repeatMode.symbol)
                            .font(.callout)
                            .foregroundStyle(controller.repeatMode == .off ? .secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Repeat: \(controller.repeatMode.rawValue.capitalized)")
                }

                // Volume & Speed Bar
                HStack(spacing: 14) {
                    Button { controller.isMuted.toggle() } label: {
                        Image(systemName: controller.isMuted || controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: Binding(
                        get: { Double(controller.isMuted ? 0 : controller.volume) },
                        set: {
                            controller.volume = Float($0)
                            controller.isMuted = ($0 == 0)
                        }
                    ), in: 0...1)
                    .frame(width: 150)
                    .controlSize(.small)

                    Menu {
                        ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button("\(String(format: "%g", r))×") { controller.playbackRate = r }
                        }
                    } label: {
                        Text("\(String(format: "%g", controller.playbackRate))×")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(28)
        }
    }

    // MARK: - Right Column: Searchable Up Next Queue

    private var queueSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Up Next")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(filteredQueue.count) track\(filteredQueue.count == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                TextField("Filter queue…", text: $queueFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(filteredQueue.enumerated()), id: \.element.id) { idx, track in
                        let isCurrent = controller.currentItem?.id == track.id
                        Button {
                            onSelectTrack(track)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 22, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.url.deletingPathExtension().lastPathComponent)
                                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                        .lineLimit(1)
                                    Text("\(track.fileExtension) · \(MediaFormatting.byteString(track.fileSize))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if isCurrent && controller.isPlaying {
                                    equalizerBars
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isCurrent ? Color.accentColor.opacity(0.11) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let art = controller.artwork {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.28), Color.indigo.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "waveform")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var equalizerBars: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Capsule().fill(.green).frame(width: 2.5, height: barPhase ? 12 : 4)
            Capsule().fill(.green).frame(width: 2.5, height: barPhase ? 5 : 13)
            Capsule().fill(.green).frame(width: 2.5, height: barPhase ? 11 : 6)
        }
        .frame(height: 14)
    }
}
