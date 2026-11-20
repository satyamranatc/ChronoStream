import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Native macOS AirPlay / Cast device picker backed by AVKit's AVRoutePickerView.
/// Discovers nearby Apple TVs, AirPlay 2 Smart TVs, HomePods, and wireless audio devices.
public struct AirPlayRoutePickerButton: NSViewRepresentable {
    let player: AVPlayer
    let tintColor: NSColor
    let activeColor: NSColor

    public init(
        player: AVPlayer,
        tintColor: NSColor = .secondaryLabelColor,
        activeColor: NSColor = .controlAccentColor
    ) {
        self.player = player
        self.tintColor = tintColor
        self.activeColor = activeColor
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = player
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(tintColor, for: .normal)
        picker.setRoutePickerButtonColor(activeColor, for: .active)
        picker.setRoutePickerButtonColor(activeColor, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(activeColor, for: .activeHighlighted)
        return picker
    }

    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
