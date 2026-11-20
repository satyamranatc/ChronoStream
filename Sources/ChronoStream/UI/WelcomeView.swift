import AppKit
import SwiftUI

public struct WelcomeView: View {
    let onAddFolder: () -> Void
    let onContinue: () -> Void

    public init(onAddFolder: @escaping () -> Void, onContinue: @escaping () -> Void) {
        self.onAddFolder = onAddFolder
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 78, height: 78)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }

                Text("Welcome to ChronoStream")
                    .font(.largeTitle.weight(.bold))

                Text("A unified, offline-first media studio built natively for macOS.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    symbol: "play.rectangle.on.rectangle",
                    title: "Videos, Music, Photos & PDFs in One Place",
                    detail: "Hardware-accelerated playback for 12–24+ hour recordings, playlists, photo slideshows, and PDF search."
                )
                featureRow(
                    symbol: "wand.and.stars",
                    title: "Built-In Photo & Video Studios",
                    detail: "Crop photos, place draggable text, build collages & animated GIFs, or trim, merge, and extract audio from videos."
                )
                featureRow(
                    symbol: "qrcode",
                    title: "Instant AirDrop & Wi-Fi QR Sharing",
                    detail: "Send files or entire collections to iPhone Safari or Android over local Wi-Fi with PIN protection — zero cloud uploads."
                )
                featureRow(
                    symbol: "lock.shield",
                    title: "Private by Design",
                    detail: "ChronoStream only reads folders you explicitly authorize via macOS security-scoped bookmarks."
                )
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 12) {
                Button("Explore Without Adding Folder") {
                    onContinue()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    onAddFolder()
                } label: {
                    Label("Add Media Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.bottom, 6)
        }
        .padding(32)
        .frame(width: 560)
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
