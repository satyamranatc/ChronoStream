import AppKit
import AVFoundation
import SwiftUI

private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct AVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

public struct VideoStageView: View {
    @Bindable var controller: VideoPlayerController
    let item: MediaItem
    let onShare: () -> Void
    let onClose: () -> Void

    @State private var showControls = true
    @State private var hoverTime: Double?
    @State private var hoverX: CGFloat = 0
    @State private var zoomWindowSeconds: Double = 0 // 0 = Full
    @State private var isDragging = false
    @State private var dragTime: Double = 0
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var isHoveringStage = false
    @State private var videoZoom: CGFloat = 1.0
    @State private var gestureBaseZoom: CGFloat = 1.0
    @State private var videoPan: CGSize = .zero
    @State private var panDragStart: CGSize = .zero
    @State private var osdText: String?
    @State private var osdSymbol: String?
    @State private var osdHideTask: Task<Void, Never>?
    @State private var showShortcutsHelp = false
    @State private var showDisplayPopover = false
    @State private var showEnhancePopover = false
    private let displayManager = DisplayManager.shared

    private let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
    private let zoomWindows: [Double] = [0, 3600, 900, 120]

    public init(controller: VideoPlayerController, item: MediaItem, onShare: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.controller = controller
        self.item = item
        self.onShare = onShare
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerSurface(player: controller.player)
                .scaleEffect(videoZoom)
                .offset(videoPan)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { val in
                            let next = min(6.0, max(1.0, gestureBaseZoom * val.magnification))
                            videoZoom = next
                            if next <= 1.01 { videoPan = .zero; panDragStart = .zero }
                            flashOSD(String(format: "Zoom %.1f×", next), symbol: "plus.magnifyingglass")
                        }
                        .onEnded { _ in
                            gestureBaseZoom = videoZoom
                        }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { val in
                            guard videoZoom > 1.01 else { return }
                            videoPan = CGSize(
                                width: panDragStart.width + val.translation.width,
                                height: panDragStart.height + val.translation.height
                            )
                        }
                        .onEnded { _ in
                            panDragStart = videoPan
                        }
                )
                .onTapGesture(count: 2) {
                    if videoZoom > 1.01 {
                        resetVideoZoom()
                    } else {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                }
                .onTapGesture(count: 1) {
                    controller.togglePlayPause()
                }

            if controller.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    if let status = controller.statusMessage {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if let error = controller.errorMessage {
                ContentUnavailableView {
                    Label("Unable to Play Video", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                } description: {
                    Text(error)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            // Transient Keyboard OSD feedback pill
            if let osdText {
                HStack(spacing: 8) {
                    if let sym = osdSymbol {
                        Image(systemName: sym)
                            .font(.callout.weight(.semibold))
                    }
                    Text(osdText)
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.76), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            // Subtitle overlay
            if let sub = controller.activeSubtitleText {
                VStack {
                    Spacer()
                    Text(sub)
                        .font(.system(size: 18, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, showControls ? 112 : 28)
                }
                .allowsHitTesting(false)
            }

            // Floating QuickTime-style HUD
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        Button(action: onClose) {
                            Label("Library", systemImage: "chevron.left")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.2))
                        .foregroundStyle(.white)

                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer()

                        Button(action: onShare) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .help("Share via AirDrop or Wi-Fi QR (Android & iPhone)")

                        Button {
                            controller.promptLoadSubtitles()
                        } label: {
                            Label(controller.subtitles.isEmpty ? "Subtitles" : "CC Active", systemImage: "captions.bubble")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.2))
                        .foregroundStyle(.white)

                        // Live GPU Video Enhancement Button & Popover
                        Button {
                            showEnhancePopover.toggle()
                        } label: {
                            Label(
                                controller.enhanceMode == .off ? "Enhance" : controller.enhanceMode.rawValue,
                                systemImage: "wand.and.stars"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(controller.enhanceMode == .off ? .white.opacity(0.2) : .teal)
                        .foregroundStyle(.white)
                        .help("Live GPU Video Enhancement (E) — Sharpen, Denoise & CCTV Clarity")
                        .popover(isPresented: $showEnhancePopover, arrowEdge: .bottom) {
                            videoEnhancePopover
                        }

                        if videoZoom > 1.01 {
                            Button {
                                resetVideoZoom()
                            } label: {
                                Label(String(format: "%.1f× · Reset", videoZoom), systemImage: "magnifyingglass")
                                    .font(.caption.monospacedDigit().weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(.teal)
                            .foregroundStyle(.white)
                            .help("Reset Video Zoom (R)")
                        }

                        if displayManager.hasExternalDisplay {
                            Button {
                                if displayManager.isExternalCinemaActive {
                                    displayManager.stopExternalCinema()
                                    flashOSD("External Cinema Off", symbol: "tv.slash")
                                } else {
                                    displayManager.startExternalCinema(player: controller.player)
                                    flashOSD("Playing on HDMI Display", symbol: "tv.fill")
                                }
                            } label: {
                                Label(displayManager.isExternalCinemaActive ? "HDMI On" : "HDMI Cinema", systemImage: "tv")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(displayManager.isExternalCinemaActive ? .teal : .white.opacity(0.2))
                            .foregroundStyle(.white)
                            .help("Send video full-screen to connected HDMI display")
                        }

                        Button {
                            showShortcutsHelp.toggle()
                        } label: {
                            Image(systemName: "keyboard")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.2))
                        .help("Keyboard Shortcuts (?)")
                        .popover(isPresented: $showShortcutsHelp, arrowEdge: .bottom) {
                            shortcutsCheatSheet
                        }

                        Button {
                            NSApp.keyWindow?.toggleFullScreen(nil)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.2))
                        .help("Full Screen (F)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Spacer()

                    // Bottom controls card
                    VStack(spacing: 8) {
                        // Precision zoom bar for long 12-24 hr videos
                        if zoomWindowSeconds > 0, controller.duration > zoomWindowSeconds {
                            precisionScrubber
                        }

                        // Main timeline with hover preview
                        mainScrubber

                        // Transport row
                        HStack(spacing: 12) {
                            Button { controller.togglePlayPause() } label: {
                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .frame(width: 26)
                            }
                            .buttonStyle(.plain)

                            Button { controller.skip(by: -10) } label: {
                                Image(systemName: "gobackward.10")
                            }
                            .buttonStyle(.plain)

                            Button { controller.skip(by: 10) } label: {
                                Image(systemName: "goforward.10")
                            }
                            .buttonStyle(.plain)

                            Text("\(MediaFormatting.timeString(isDragging ? dragTime : controller.currentTime)) / \(MediaFormatting.timeString(controller.duration))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Spacer()

                            // Precision zoom picker
                            Menu {
                                Button("Full Timeline") { zoomWindowSeconds = 0 }
                                Button("1 Hour Window") { zoomWindowSeconds = 3600 }
                                Button("15 Min Window") { zoomWindowSeconds = 900 }
                                Button("2 Min Window") { zoomWindowSeconds = 120 }
                            } label: {
                                Text(zoomWindowSeconds == 0 ? "Full" : (zoomWindowSeconds >= 3600 ? "1 hr" : "\(Int(zoomWindowSeconds / 60))m"))
                                    .font(.caption.weight(.medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()

                            // Speed picker
                            Menu {
                                ForEach(speeds, id: \.self) { rate in
                                    Button("\(rate == 1.0 ? "1" : String(format: "%g", rate))×") {
                                        controller.playbackRate = rate
                                    }
                                }
                            } label: {
                                Text("\(String(format: "%g", controller.playbackRate))×")
                                    .font(.caption.monospacedDigit().weight(.medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()

                            // Volume
                            HStack(spacing: 6) {
                                Button { controller.isMuted.toggle() } label: {
                                    Image(systemName: controller.isMuted || controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)

                                Slider(value: Binding(
                                    get: { Double(controller.isMuted ? 0 : controller.volume) },
                                    set: {
                                        controller.volume = Float($0)
                                        controller.isMuted = ($0 == 0)
                                    }
                                ), in: 0...1)
                                .frame(width: 72)
                                .controlSize(.small)
                            }

                            // Native AirPlay / Cast picker
                            AirPlayRoutePickerButton(
                                player: controller.player,
                                tintColor: .labelColor
                            )
                            .frame(width: 24, height: 22)
                            .help("AirPlay / Cast to Apple TV, Smart TV, or Speaker")
                        }
                        .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
                .transition(.opacity)
            }
        }
        .onHover { inside in
            isHoveringStage = inside
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = inside || !controller.isPlaying || showEnhancePopover || showShortcutsHelp
            }
        }
        .onChange(of: showEnhancePopover) { _, open in
            if open {
                showControls = true
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = isHoveringStage || !controller.isPlaying || showShortcutsHelp
                }
            }
        }
        .onChange(of: showShortcutsHelp) { _, open in
            if open {
                showControls = true
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = isHoveringStage || !controller.isPlaying || showEnhancePopover
                }
            }
        }
        .onAppear {
            controller.load(item)
            installKeyMonitor()
        }
        .onChange(of: item.id) { _, _ in
            resetVideoZoom(silent: true)
            controller.load(item)
        }
        .onDisappear {
            removeKeyMonitor()
            osdHideTask?.cancel()
            displayManager.stopExternalCinema()
            controller.stop()
        }
    }

    private func applyVideoZoom(_ next: CGFloat) {
        let clamped = min(6.0, max(1.0, next))
        videoZoom = clamped
        gestureBaseZoom = clamped
        if clamped <= 1.01 {
            videoPan = .zero
            panDragStart = .zero
        }
        flashOSD(String(format: "Zoom %.1f×", clamped), symbol: clamped > 1.01 ? "plus.magnifyingglass" : "1.magnifyingglass")
    }

    private func resetVideoZoom(silent: Bool = false) {
        withAnimation(.easeOut(duration: 0.18)) {
            videoZoom = 1.0
            gestureBaseZoom = 1.0
            videoPan = .zero
            panDragStart = .zero
        }
        if !silent {
            flashOSD("Zoom 1.0×", symbol: "1.magnifyingglass")
        }
    }

    // MARK: - Keyboard Shortcuts, Scroll Zoom & OSD

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Do not hijack keys while typing in a search field or text editor
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // Ignore Cmd / Ctrl / Option system shortcuts (e.g. ⌘Q, ⌘W, ⌘O)
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if !mods.isEmpty {
                return event
            }
            return handleKeyDown(event) ? nil : event
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHoveringStage else { return event }
            let dy = event.scrollingDeltaY
            guard abs(dy) > 0.05 else { return event }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? dy * 0.008 : dy * 0.08
            let next = min(6.0, max(1.0, videoZoom + step))
            if abs(next - videoZoom) > 0.005 {
                applyVideoZoom(next)
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let sMonitor = scrollMonitor {
            NSEvent.removeMonitor(sMonitor)
            scrollMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // Space
            controller.togglePlayPause()
            flashOSD(controller.isPlaying ? "Play" : "Paused", symbol: controller.isPlaying ? "play.fill" : "pause.fill")
            return true
        case 123: // Left arrow
            let delta: Double = shift ? -30 : -5
            controller.skip(by: delta)
            flashOSD("\(Int(delta))s", symbol: "gobackward")
            return true
        case 124: // Right arrow
            let delta: Double = shift ? 30 : 5
            controller.skip(by: delta)
            flashOSD("+\(Int(delta))s", symbol: "goforward")
            return true
        case 126: // Up arrow
            let nextVol = min(1.0, (controller.isMuted ? 0 : controller.volume) + 0.1)
            controller.volume = nextVol
            controller.isMuted = false
            flashOSD("Volume \(Int((nextVol * 100).rounded()))%", symbol: "speaker.wave.2.fill")
            return true
        case 125: // Down arrow
            let nextVol = max(0.0, controller.volume - 0.1)
            controller.volume = nextVol
            controller.isMuted = (nextVol == 0)
            flashOSD(nextVol == 0 ? "Muted" : "Volume \(Int((nextVol * 100).rounded()))%", symbol: nextVol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
            return true
        case 53: // Escape
            if showEnhancePopover {
                showEnhancePopover = false
            } else if showShortcutsHelp {
                showShortcutsHelp = false
            } else if let win = NSApp.keyWindow, win.styleMask.contains(.fullScreen) {
                win.toggleFullScreen(nil)
            } else {
                onClose()
            }
            return true
        case 51: // Backspace — reset speed
            controller.playbackRate = 1.0
            flashOSD("Speed 1×", symbol: "gauge.medium")
            return true
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else {
            return false
        }

        switch chars {
        case "k":
            controller.togglePlayPause()
            flashOSD(controller.isPlaying ? "Play" : "Paused", symbol: controller.isPlaying ? "play.fill" : "pause.fill")
            return true
        case "j":
            controller.skip(by: -10)
            flashOSD("-10s", symbol: "gobackward.10")
            return true
        case "l":
            controller.skip(by: 10)
            flashOSD("+10s", symbol: "goforward.10")
            return true
        case ",":
            controller.stepFrame(by: -1)
            flashOSD("Frame -1", symbol: "backward.frame.fill")
            return true
        case ".":
            controller.stepFrame(by: 1)
            flashOSD("Frame +1", symbol: "forward.frame.fill")
            return true
        case "[", "<":
            stepSpeed(delta: -1)
            return true
        case "]", ">":
            stepSpeed(delta: 1)
            return true
        case "\\":
            controller.playbackRate = 1.0
            flashOSD("Speed 1×", symbol: "gauge.medium")
            return true
        case "m":
            controller.isMuted.toggle()
            flashOSD(controller.isMuted ? "Muted" : "Unmuted", symbol: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            return true
        case "f":
            NSApp.keyWindow?.toggleFullScreen(nil)
            return true
        case "=", "+":
            applyVideoZoom(videoZoom + 0.25)
            return true
        case "-":
            applyVideoZoom(videoZoom - 0.25)
            return true
        case "r":
            resetVideoZoom()
            return true
        case "e":
            controller.cycleEnhanceMode()
            flashOSD("Enhance: \(controller.enhanceMode.rawValue)", symbol: "wand.and.stars")
            return true
        case "c":
            controller.promptLoadSubtitles()
            return true
        case "z":
            if let idx = zoomWindows.firstIndex(of: zoomWindowSeconds) {
                zoomWindowSeconds = zoomWindows[(idx + 1) % zoomWindows.count]
            } else {
                zoomWindowSeconds = 0
            }
            let label = zoomWindowSeconds == 0 ? "Full Timeline" : (zoomWindowSeconds >= 3600 ? "1 hr Window" : "\(Int(zoomWindowSeconds / 60))m Window")
            flashOSD(label, symbol: "magnifyingglass")
            return true
        case "?", "/":
            if shift || chars == "?" {
                showShortcutsHelp.toggle()
                return true
            }
            return false
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let digit = Int(chars), controller.duration > 0 {
                let pct = Double(digit) / 10.0
                controller.seek(to: controller.duration * pct)
                flashOSD("\(digit * 10)%", symbol: "timeline.selection")
                return true
            }
            return false
        default:
            return false
        }
    }

    private func stepSpeed(delta: Int) {
        let currentIdx = speeds.firstIndex(where: { abs($0 - controller.playbackRate) < 0.01 }) ?? 3
        let nextIdx = max(0, min(speeds.count - 1, currentIdx + delta))
        let rate = speeds[nextIdx]
        controller.playbackRate = rate
        flashOSD("Speed \(String(format: "%g", rate))×", symbol: "gauge.with.needle")
    }

    private func flashOSD(_ text: String, symbol: String? = nil) {
        osdHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.14)) {
            osdText = text
            osdSymbol = symbol
        }
        osdHideTask = Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                osdText = nil
                osdSymbol = nil
            }
        }
    }

    private var videoEnhancePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Live GPU Enhancement", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                Text("Real-Time · Metal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teal)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.teal.opacity(0.12), in: Capsule())
            }

            // Preset Modes
            VStack(spacing: 6) {
                ForEach(VideoEnhanceMode.allCases) { mode in
                    let active = controller.enhanceMode == mode
                    Button {
                        controller.setEnhanceMode(mode)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(active ? Color.teal : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.rawValue)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(mode.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(active ? Color.teal.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if controller.enhanceMode != .off {
                Divider()

                VStack(spacing: 10) {
                    enhanceSliderRow("Sharpness & Edges", value: Binding(
                        get: { controller.enhanceParams.sharpness },
                        set: { var p = controller.enhanceParams; p.sharpness = $0; controller.updateEnhanceParams(p) }
                    ), range: 0...2.0)

                    enhanceSliderRow("Denoise (Low-Light)", value: Binding(
                        get: { controller.enhanceParams.denoise },
                        set: { var p = controller.enhanceParams; p.denoise = $0; controller.updateEnhanceParams(p) }
                    ), range: 0...0.08)

                    enhanceSliderRow("Shadow Lift (Night CCTV)", value: Binding(
                        get: { controller.enhanceParams.shadowLift },
                        set: { var p = controller.enhanceParams; p.shadowLift = $0; controller.updateEnhanceParams(p) }
                    ), range: 0...0.8)

                    enhanceSliderRow("Clarity Contrast", value: Binding(
                        get: { controller.enhanceParams.contrast },
                        set: { var p = controller.enhanceParams; p.contrast = $0; controller.updateEnhanceParams(p) }
                    ), range: 0.9...1.35)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func enhanceSliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .tint(.teal)
                .controlSize(.small)
        }
    }

    private var shortcutsCheatSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video Keyboard Shortcuts")
                .font(.headline)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                shortcutRow("Space / K", "Play / Pause")
                shortcutRow("← / →", "Seek -5s / +5s")
                shortcutRow("⇧← / ⇧→", "Seek -30s / +30s")
                shortcutRow("J / L", "Seek -10s / +10s")
                shortcutRow(", / .", "Previous / Next Frame")
                shortcutRow("0 – 9", "Jump to 0% – 90%")
                shortcutRow("[ / ]", "Decrease / Increase Speed")
                shortcutRow("⌫ / \\", "Reset Speed (1×)")
                shortcutRow("↑ / ↓", "Volume Up / Down")
                shortcutRow("M", "Mute / Unmute")
                shortcutRow("F", "Toggle Full Screen")
                shortcutRow("Pinch / Scroll", "Zoom Live Video (1×–6×)")
                shortcutRow("+ / - / R", "Zoom In / Out / Reset")
                shortcutRow("E", "Cycle Live GPU Enhancement")
                shortcutRow("Z", "Cycle Precision Zoom")
                shortcutRow("C", "Load Subtitles")
                shortcutRow("Esc", "Exit Full Screen / Back")
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 270)
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        GridRow {
            Text(keys)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(desc)
                .foregroundStyle(.secondary)
        }
    }

    private var mainScrubber: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let dur = max(0.001, controller.duration)
            let displayTime = isDragging ? dragTime : controller.currentTime
            let progress = min(1, max(0, displayTime / dur))

            ZStack(alignment: .leading) {
                // Hover preview tooltip
                if let hTime = hoverTime {
                    VStack(spacing: 4) {
                        if let img = controller.hoverPreviewImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 176, height: 99)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text(MediaFormatting.timeString(hTime))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(6)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .position(x: min(max(96, hoverX), width - 96), y: -64)
                    .animation(nil, value: hoverX)
                    .allowsHitTesting(false)
                }

                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 5)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress, height: 5)

                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * progress - 6)))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    let ratio = min(1, max(0, loc.x / width))
                    let t = ratio * dur
                    hoverX = loc.x
                    hoverTime = t
                    controller.requestHoverPreview(at: t)
                case .ended:
                    hoverTime = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let ratio = min(1, max(0, value.location.x / width))
                        dragTime = ratio * dur
                        hoverX = value.location.x
                        hoverTime = dragTime
                        controller.requestHoverPreview(at: dragTime)
                    }
                    .onEnded { value in
                        let ratio = min(1, max(0, value.location.x / width))
                        let target = ratio * dur
                        isDragging = false
                        controller.seek(to: target)
                    }
            )
        }
        .frame(height: 18)
    }

    private var precisionScrubber: some View {
        let dur = max(0.001, controller.duration)
        let cur = controller.currentTime
        let start = max(0, min(dur - zoomWindowSeconds, cur - zoomWindowSeconds / 2))
        let end = min(dur, start + zoomWindowSeconds)
        let span = max(1, end - start)
        let pct = min(1, max(0, (cur - start) / span))

        return VStack(spacing: 3) {
            HStack {
                Text("Precision Window")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(MediaFormatting.timeString(start)) – \(MediaFormatting.timeString(end))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                    Capsule().fill(Color.teal).frame(width: w * pct, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { val in
                            let r = min(1, max(0, val.location.x / w))
                            controller.seek(to: start + r * span)
                        }
                )
            }
            .frame(height: 10)
        }
    }
}
