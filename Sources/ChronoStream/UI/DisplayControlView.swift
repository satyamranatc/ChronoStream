import AVFoundation
import SwiftUI

/// Native Apple Control Center–inspired Displays popover for ChronoStream.
public struct DisplayControlPopover: View {
    @Bindable var displayManager: DisplayManager
    let activeVideoPlayer: AVPlayer?

    public init(displayManager: DisplayManager = .shared, activeVideoPlayer: AVPlayer? = nil) {
        self.displayManager = displayManager
        self.activeVideoPlayer = activeVideoPlayer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Minimal Control Center Header
            HStack(alignment: .center) {
                Text("Displays")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(displayManager.hasExternalDisplay ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(statusPillText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.06), in: Capsule())

                Button {
                    displayManager.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh Displays")
            }

            // Connected Displays Card (Apple Settings grouped style)
            VStack(spacing: 0) {
                ForEach(Array(displayManager.displays.enumerated()), id: \.element.id) { idx, display in
                    if idx > 0 {
                        Divider().padding(.leading, 52)
                    }
                    displayRow(display)
                }
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
            )

            // Grouped Switches Card (macOS System Settings pattern)
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep External Display Awake")
                            .font(.callout)
                        Text("Prevents idle sleep while connected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $displayManager.keepDisplayAwake)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().padding(.leading, 12)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Follow Lid Close")
                            .font(.callout)
                        Text("Moves ChronoStream onto HDMI automatically")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $displayManager.autoRescueOnLidClose)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
            )

            // Quiet contextual footnote (only shown when relevant)
            if displayManager.hasExternalDisplay && !displayManager.isOnACPower {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Connect power adapter for lid-closed Clamshell mode.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .frame(width: 344)
        .onAppear {
            displayManager.refreshDisplays()
        }
    }

    private func displayRow(_ display: ConnectedDisplayInfo) -> some View {
        let isCinema = displayManager.isExternalCinemaActive && displayManager.activeCinemaDisplayID == display.id

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(display.isBuiltIn ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(display.isBuiltIn ? Color.primary : Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isCinema {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(display.isMain ? "\(display.resolutionLabel) · Main" : display.resolutionLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if displayManager.displays.count > 1 {
                Button("Move") {
                    displayManager.moveMainWindow(to: display.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if !display.isBuiltIn, let player = activeVideoPlayer {
                Button(isCinema ? "Stop" : "Cinema") {
                    if isCinema {
                        displayManager.stopExternalCinema()
                    } else {
                        displayManager.startExternalCinema(player: player, on: display.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isCinema ? .red : .accentColor)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusPillText: String {
        if displayManager.isLidClosed && displayManager.hasExternalDisplay {
            return "Clamshell Active"
        } else if displayManager.hasExternalDisplay {
            return displayManager.isOnACPower ? "HDMI · AC Power" : "HDMI · Battery"
        } else {
            return displayManager.isOnACPower ? "AC Power" : "Battery"
        }
    }
}
