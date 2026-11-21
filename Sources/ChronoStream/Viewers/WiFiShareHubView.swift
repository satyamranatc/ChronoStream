import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum WiFiShareDirection: String, CaseIterable, Identifiable {
    case sendToPhone = "Send"
    case receiveFromPhone = "Receive"
    var id: String { rawValue }
}

/// Unified, security-hardened two-way Wi-Fi file sharing hub between Mac and Android / iPhone.
/// Uses random 24-character session tokens, 4-digit PIN gates, brute-force lockout, and 10-min auto-expiry.
public struct WiFiShareHubView: View {
    @State private var direction: WiFiShareDirection = .sendToPhone
    @State private var sendSession = LocalShareSession()
    @State private var receiveServer = SecureWiFiReceiver()
    @State private var selectedSendItems: [MediaItem] = []
    @State private var isDropTargeted = false
    @State private var copiedLink = false

    let onOpenReceivedURL: (URL) -> Void

    public init(onOpenReceivedURL: @escaping (URL) -> Void) {
        self.onOpenReceivedURL = onOpenReceivedURL
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            switch direction {
            case .sendToPhone:
                sendToPhoneBody
            case .receiveFromPhone:
                receiveFromPhoneBody
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            sendSession.stop()
            receiveServer.stop()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.teal.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "qrcode.viewfinder")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.teal)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Wi-Fi Share")
                    .font(.headline)
                    .lineLimit(1)
                Text("Android & iPhone · PIN Protected · Zero Cloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Picker("", selection: $direction) {
                ForEach(WiFiShareDirection.allCases) { dir in
                    Text(dir.rawValue).tag(dir)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: - Tab 1: Send to Phone (Mac -> Android / iPhone)

    private var sendToPhoneBody: some View {
        HSplitView {
            // Left: File Picker & Queue
            VStack(spacing: 0) {
                HStack {
                    Text("Files to Send (\(selectedSendItems.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        pickFilesToSend()
                    } label: {
                        Label("Choose Files…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .controlSize(.small)

                    if !selectedSendItems.isEmpty {
                        Button("Clear") {
                            sendSession.stop()
                            selectedSendItems.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if selectedSendItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "arrow.up.doc.on.clipboard")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.teal)
                        Text("Drop files here or click Choose Files")
                            .font(.headline)
                        Text("Send videos, photos, music, PDFs, or Word (.docx) files straight to any Android or iPhone over the same Wi-Fi.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                        Button {
                            pickFilesToSend()
                        } label: {
                            Label("Choose Files from Mac…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        Spacer()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(selectedSendItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.kind.systemImage)
                                    .foregroundStyle(Color.teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(MediaFormatting.byteString(item.fileSize))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedSendItems.removeAll { $0.id == item.id }
                                    if selectedSendItems.isEmpty {
                                        sendSession.stop()
                                    } else if sendSession.isRunning {
                                        sendSession.start(items: selectedSendItems)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                        .background(Color.teal.opacity(0.06))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedFiles(providers)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            .background(Color(nsColor: .controlBackgroundColor))

            // Right: Secure QR & AirDrop Panel
            ScrollView {
                VStack(spacing: 16) {
                    if sendSession.isRunning, let qr = sendSession.qrImage {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 190, height: 190)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)

                        VStack(spacing: 5) {
                            Text("Scan with Android or iPhone")
                                .font(.title3.weight(.bold))
                            Text("Opens in Chrome or Safari — no phone app required.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        // 4-Digit Security PIN Badge
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Color.teal)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("SECURITY PIN")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(sendSession.pinCode)
                                    .font(.title3.monospacedDigit().weight(.bold))
                                    .tracking(4)
                            }
                            Divider().frame(height: 24)
                            Toggle("PIN", isOn: $sendSession.requirePin)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.teal.opacity(0.3), lineWidth: 1))

                        HStack(spacing: 8) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sendSession.shareURL, forType: .string)
                                copiedLink = true
                            } label: {
                                Label(copiedLink ? "Copied" : "Copy Link", systemImage: copiedLink ? "checkmark" : "link")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                presentAirDrop()
                            } label: {
                                Label("AirDrop", systemImage: "airplayaudio")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Stop", role: .destructive) {
                                sendSession.stop()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("Auto-expires after 10 minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.teal)
                            .padding(.top, 24)
                        Text(selectedSendItems.isEmpty ? "Select files on the left to start" : "Ready to generate secure QR")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text("Protected by a one-time 24-character token, 4-digit PIN, and automatic 10-minute shutdown.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)

                        HStack(spacing: 10) {
                            Button {
                                copiedLink = false
                                sendSession.start(items: selectedSendItems)
                            } label: {
                                Label("Start QR Share", systemImage: "qrcode")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .disabled(selectedSendItems.isEmpty)

                            if !selectedSendItems.isEmpty {
                                Button {
                                    presentAirDrop()
                                } label: {
                                    Label("AirDrop", systemImage: "airplayaudio")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Tab 2: Receive from Phone (Android / iPhone -> Mac)

    private var receiveFromPhoneBody: some View {
        HSplitView {
            // Left: Secure Receive QR Panel
            VStack(spacing: 16) {
                Spacer()

                if receiveServer.isRunning, let qr = receiveServer.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 210, height: 210)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)

                    VStack(spacing: 6) {
                        Text("Scan with Android or iPhone Camera")
                            .font(.title3.weight(.bold))
                        Text("Enter the 4-digit PIN on your phone to unlock secure LAN upload (auto-locks after 5 wrong tries).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(Color.teal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SECURITY PIN")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(receiveServer.securityPIN)
                                .font(.title3.monospacedDigit().weight(.bold))
                                .tracking(4)
                        }
                        Button {
                            receiveServer.rotatePIN()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Rotate Security PIN")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.teal.opacity(0.3), lineWidth: 1))

                    HStack(spacing: 10) {
                        if let url = receiveServer.receiverURL {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Stop Session", role: .destructive) {
                            receiveServer.stop()
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Auto-expires in \(MediaFormatting.timeString(Double(receiveServer.secondsRemaining)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "iphone.and.arrow.right.inward")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.teal)
                    Text("Receive Files from Android or iPhone")
                        .font(.title3.weight(.bold))
                    Text("No open port stays running in the background. Click below to start a temporary 10-minute PIN-protected Wi-Fi session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)

                    Button {
                        receiveServer.start()
                    } label: {
                        Label("Start Secure Receive Session", systemImage: "lock.shield.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                }

                if let err = receiveServer.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                } else if let status = receiveServer.statusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

            // Right: Received Files Inbox
            VStack(spacing: 0) {
                HStack {
                    Text("Received Inbox (\(receiveServer.receivedFiles.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(SecureWiFiReceiver.inboxDirectory)
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if receiveServer.receivedFiles.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "tray.and.arrow.down")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("No files received yet")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Saved to ~/Downloads/ChronoStream Inbox")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                } else {
                    List(receiveServer.receivedFiles) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(Color.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("\(MediaFormatting.byteString(file.fileSize)) · \(file.receivedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") {
                                onOpenReceivedURL(file.url)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .controlSize(.mini)
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("Open in ChronoStream") { onOpenReceivedURL(file.url) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 220, idealWidth: 270, maxWidth: 360, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Helpers

    private func pickFilesToSend() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files to Share Over Wi-Fi"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addURLsToSendQueue(panel.urls)
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    addURLsToSendQueue([url])
                }
            }
        }
        return true
    }

    private func addURLsToSendQueue(_ urls: [URL]) {
        for url in urls {
            guard !selectedSendItems.contains(where: { $0.path == url.path }) else { continue }
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let mod = vals?.contentModificationDate ?? Date()
            let kind = MediaFormatRegistry.kind(for: url) ?? .pdf
            selectedSendItems.append(
                MediaItem(
                    url: url,
                    kind: kind,
                    fileSize: size,
                    modifiedDate: mod
                )
            )
        }
        if !selectedSendItems.isEmpty {
            copiedLink = false
            sendSession.start(items: selectedSendItems)
        }
    }

    private func presentAirDrop() {
        let urls = selectedSendItems.map(\.url)
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}
