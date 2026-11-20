import AppKit
import SwiftUI

/// Native Apple Sharing Sheet: AirDrop & NSSharingServicePicker + Local Wi-Fi QR Transfer + Copy Link.
public struct ShareSheetView: View {
    let items: [MediaItem]
    @Bindable var session: LocalShareSession
    let onClose: () -> Void

    @State private var copiedFeedback = false

    public init(items: [MediaItem], session: LocalShareSession, onClose: @escaping () -> Void) {
        self.items = items
        self.session = session
        self.onClose = onClose
    }

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Media")
                        .font(.headline)
                    Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(MediaFormatting.byteString(totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    session.stop()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            // Method 1: Apple Native Sharing (AirDrop & System Share Sheet)
            VStack(spacing: 10) {
                shareOptionRow(
                    title: "AirDrop & Apple Share",
                    subtitle: "Share directly with nearby iPhone, iPad, or Mac",
                    systemImage: "airplayaudio"
                ) {
                    presentNativeSharePicker()
                }

                // Method 2: Wi-Fi QR Sharing
                shareOptionRow(
                    title: session.isRunning ? "Wi-Fi QR Sharing Active" : "Share via QR Code",
                    subtitle: "Scan with iPhone Safari or Android on the same Wi-Fi",
                    systemImage: "qrcode"
                ) {
                    if !session.isRunning {
                        session.start(items: items)
                    }
                }

                // Method 3: Copy Temporary Share Link
                shareOptionRow(
                    title: copiedFeedback ? "Link Copied" : "Copy Share Link",
                    subtitle: "Copy temporary local Wi-Fi link to clipboard",
                    systemImage: copiedFeedback ? "checkmark.circle.fill" : "link"
                ) {
                    if !session.isRunning {
                        session.start(items: items)
                    }
                    if !session.shareURL.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.shareURL, forType: .string)
                        copiedFeedback = true
                    }
                }
            }

            // Active Wi-Fi QR Session Panel
            if session.isRunning {
                Divider()
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = session.qrImage {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 156, height: 156)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with iPhone Camera")
                                .font(.subheadline.weight(.semibold))
                            Text("Opens directly in Safari — no iPhone app required.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if session.requirePin {
                                HStack(spacing: 6) {
                                    Text("PIN:")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Text(session.pinCode)
                                        .font(.title3.monospacedDigit().weight(.bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }

                            Text(session.shareURL)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(session.shareURL, forType: .string)
                                    copiedFeedback = true
                                }
                                .controlSize(.small)

                                Button("Revoke & Stop", role: .destructive) {
                                    session.stop()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // Active Connections & Transfer Progress
                    if !session.transfers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transfers (\(session.connectedClients.count) device\(session.connectedClients.count == 1 ? "" : "s"))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(session.transfers.prefix(4)) { tr in
                                HStack {
                                    Text(tr.fileName)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    if tr.isComplete {
                                        Label("Done", systemImage: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    } else {
                                        ProgressView(value: Double(tr.bytesSent), total: Double(max(1, tr.totalBytes)))
                                            .frame(width: 80)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if let err = session.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onDisappear {
            session.stop()
        }
    }

    private func shareOptionRow(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func presentNativeSharePicker() {
        let urls = items.map(\.url)
        guard !urls.isEmpty, let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let rect = NSRect(x: contentView.bounds.midX - 10, y: contentView.bounds.midY, width: 20, height: 20)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }
}
