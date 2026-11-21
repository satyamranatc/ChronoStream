import AppKit
import Foundation

/// Subtle, zero-latency macOS click sound feedback backed by native system sounds.
@MainActor
public final class UISoundFeedback {
    public static let shared = UISoundFeedback()

    private var cachedSounds: [String: NSSound] = [:]
    private var mouseMonitor: Any?

    private init() {}

    public func installGlobalClickMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if UserDefaults.standard.object(forKey: "uiClickSoundEnabled") as? Bool ?? true {
                // Skip clicks inside editable text views (Doc Writer canvas) so typing/cursor placement stays quiet
                if let win = event.window,
                   let hit = win.contentView?.hitTest(event.locationInWindow),
                   !(hit is NSTextView) {
                    self.playClick()
                }
            }
            return event
        }
    }

    public func playClick() {
        let name = UserDefaults.standard.string(forKey: "uiClickSoundName") ?? "Tink"
        let sound: NSSound?
        if let existing = cachedSounds[name] {
            sound = existing
        } else if let loaded = NSSound(named: NSSound.Name(name)) {
            loaded.volume = 0.22
            cachedSounds[name] = loaded
            sound = loaded
        } else {
            sound = nil
        }

        if let s = sound {
            if s.isPlaying { s.stop() }
            s.play()
        }
    }
}
