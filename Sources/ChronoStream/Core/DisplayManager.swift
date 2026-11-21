import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import SwiftUI

public struct ConnectedDisplayInfo: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let width: Int
    public let height: Int
    public let refreshRateHz: Int
    public let scaleFactor: CGFloat
    public let isBuiltIn: Bool
    public let isMain: Bool

    public var resolutionLabel: String {
        let hz = refreshRateHz > 0 ? " · \(refreshRateHz) Hz" : ""
        let retina = scaleFactor >= 2.0 ? " Retina" : ""
        return "\(width)×\(height)\(retina)\(hz)"
    }
}

/// Borderless external-screen video host view for Dual-Screen Cinema / HDMI Presentation mode.
private final class ExternalVideoNSView: NSView {
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

/// Smart multi-display, HDMI detection, Clamshell (lid-closed) awareness,
/// IOKit Keep-Awake assertion, and External Cinema Window manager.
@MainActor
@Observable
public final class DisplayManager {
    public static let shared = DisplayManager()

    public var displays: [ConnectedDisplayInfo] = []
    public var isLidClosed: Bool = false
    public var isOnACPower: Bool = true
    public var keepDisplayAwake: Bool = true {
        didSet { updatePowerAssertion() }
    }
    public var autoRescueOnLidClose: Bool = true
    public var isExternalCinemaActive: Bool = false
    public var activeCinemaDisplayID: CGDirectDisplayID?
    public var lastEventBanner: String?

    public var externalDisplays: [ConnectedDisplayInfo] {
        displays.filter { !$0.isBuiltIn }
    }

    public var hasExternalDisplay: Bool {
        !externalDisplays.isEmpty
    }

    public var clamshellReady: Bool {
        hasExternalDisplay && isOnACPower
    }

    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var hasActiveAssertion = false
    private var cinemaWindow: NSWindow?
    private var previousExternalIDs: Set<CGDirectDisplayID> = []
    private var pollTimer: Timer?

    private init() {
        refreshDisplays(initial: true)
        updatePowerAssertion()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplays(initial: false)
            }
        }

        // Lightweight 3s poll for lid clamshell state & AC power status (IOKit registry read)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPowerAndLidState()
            }
        }
    }

    public func refreshDisplays(initial: Bool = false) {
        let mainID = CGMainDisplayID()
        let currentScreens = NSScreen.screens

        var infos: [ConnectedDisplayInfo] = []
        for screen in currentScreens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let did = CGDirectDisplayID(num.uint32Value)
            let isBuiltIn = CGDisplayIsBuiltin(did) != 0
            let mode = CGDisplayCopyDisplayMode(did)
            let w = mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            let h = mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            let hz = Int((mode?.refreshRate ?? 60).rounded())

            infos.append(
                ConnectedDisplayInfo(
                    id: did,
                    name: screen.localizedName,
                    width: w,
                    height: h,
                    refreshRateHz: hz,
                    scaleFactor: screen.backingScaleFactor,
                    isBuiltIn: isBuiltIn,
                    isMain: did == mainID
                )
            )
        }

        let newExternalIDs = Set(infos.filter { !$0.isBuiltIn }.map(\.id))
        let newlyConnected = newExternalIDs.subtracting(previousExternalIDs)
        let disconnected = previousExternalIDs.subtracting(newExternalIDs)

        self.displays = infos
        self.previousExternalIDs = newExternalIDs
        refreshPowerAndLidState()
        updatePowerAssertion()

        if !initial {
            if let firstNew = newlyConnected.first,
               let info = infos.first(where: { $0.id == firstNew }) {
                lastEventBanner = "External display connected: \(info.name) (\(info.resolutionLabel))"
                scheduleBannerDismiss()
            } else if !disconnected.isEmpty {
                if let cinemaID = activeCinemaDisplayID, disconnected.contains(cinemaID) {
                    stopExternalCinema()
                }
                lastEventBanner = "External display disconnected"
                scheduleBannerDismiss()
            }

            // If laptop lid closed or built-in display disappeared, rescue main window onto active HDMI screen
            if autoRescueOnLidClose, let targetExternal = infos.first(where: { !$0.isBuiltIn }),
               infos.allSatisfy({ !$0.isBuiltIn }) || isLidClosed {
                moveMainWindow(to: targetExternal.id)
            }
        }
    }

    public func refreshPowerAndLidState() {
        let wasClosed = isLidClosed
        isLidClosed = Self.readClamshellClosedState()
        isOnACPower = Self.readIsOnACPower()

        if !wasClosed && isLidClosed && hasExternalDisplay {
            updatePowerAssertion()
            if autoRescueOnLidClose, let ext = externalDisplays.first {
                moveMainWindow(to: ext.id)
                lastEventBanner = "Lid closed — keeping \(ext.name) active"
                scheduleBannerDismiss()
            }
        }
    }

    // MARK: - Window & Cinema Controls

    public func moveMainWindow(to displayID: CGDirectDisplayID) {
        guard let targetScreen = screen(for: displayID),
              let win = NSApp.windows.first(where: { $0 !== cinemaWindow && $0.isVisible && $0.canBecomeMain }) else {
            return
        }
        let targetFrame = targetScreen.visibleFrame
        let newW = min(win.frame.width, targetFrame.width)
        let newH = min(win.frame.height, targetFrame.height)
        let newOrigin = NSPoint(
            x: targetFrame.midX - newW / 2,
            y: targetFrame.midY - newH / 2
        )
        win.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)), display: true, animate: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Launches a dedicated full-screen Cinema window on the chosen external HDMI display
    /// showing the live AVPlayer while keeping the main MacBook screen free for browsing & controls.
    public func startExternalCinema(player: AVPlayer, on displayID: CGDirectDisplayID? = nil) {
        let targetID = displayID ?? externalDisplays.first?.id
        guard let did = targetID, let targetScreen = screen(for: did) else { return }

        stopExternalCinema()

        let win = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )
        win.level = .floating
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostView = ExternalVideoNSView(frame: NSRect(origin: .zero, size: targetScreen.frame.size))
        hostView.playerLayer.player = player
        win.contentView = hostView
        win.setFrame(targetScreen.frame, display: true)
        win.orderFrontRegardless()

        cinemaWindow = win
        activeCinemaDisplayID = did
        isExternalCinemaActive = true
        updatePowerAssertion()
    }

    public func stopExternalCinema() {
        if let win = cinemaWindow {
            (win.contentView as? ExternalVideoNSView)?.playerLayer.player = nil
            win.orderOut(nil)
            cinemaWindow = nil
        }
        activeCinemaDisplayID = nil
        isExternalCinemaActive = false
        updatePowerAssertion()
    }

    // MARK: - Native IOKit Power & Clamshell Assertion

    private func updatePowerAssertion() {
        let shouldHold = keepDisplayAwake && (hasExternalDisplay || isExternalCinemaActive)
        if shouldHold && !hasActiveAssertion {
            let reason = "ChronoStream keeping external HDMI display awake" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displaySleepAssertionID
            )
            hasActiveAssertion = (result == kIOReturnSuccess)
        } else if !shouldHold && hasActiveAssertion {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
            hasActiveAssertion = false
        }
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(num.uint32Value) == displayID
        }
    }

    private func scheduleBannerDismiss() {
        let current = lastEventBanner
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.lastEventBanner == current {
                self.lastEventBanner = nil
            }
        }
    }

    private static func readClamshellClosedState() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        if let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return prop
        }
        return false
    }

    private static func readIsOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as? String else { return true }
        return type == kIOPMACPowerKey
    }
}
