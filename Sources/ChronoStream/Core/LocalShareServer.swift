import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation

public struct ShareTransferRecord: Identifiable, Sendable {
    public let id = UUID()
    public let clientAddress: String
    public let fileName: String
    public let totalBytes: Int64
    public var bytesSent: Int64
    public var isComplete: Bool
    public let startedAt: Date
}

/// Native macOS temporary Wi-Fi file sharing server built on Apple's Network framework (NWListener)
/// and Core Image (CIQRCodeGenerator). Zero external dependencies, strict token+PIN gating,
/// streamed file transfer (never loads large files into RAM), and automatic session expiry.
@MainActor
@Observable
public final class LocalShareSession {
    public var isRunning: Bool = false
    public var shareURL: String = ""
    public var pinCode: String = ""
    public var requirePin: Bool = true
    public var qrImage: NSImage?
    public var sharedItems: [MediaItem] = []
    public var connectedClients: [String] = []
    public var transfers: [ShareTransferRecord] = []
    public var errorMessage: String?
    public var expiresAt: Date?

    private var listener: NWListener?
    private var expiryTask: Task<Void, Never>?
    private var token: String = ""
    private var authorizedClients: Set<String> = []
    private let queue = DispatchQueue(label: "com.satyamrana.chronostream.share", qos: .userInitiated)

    public init() {}

    public func start(items: [MediaItem], ttlSeconds: TimeInterval = 600) {
        stop()
        guard !items.isEmpty else {
            errorMessage = "No files selected to share."
            return
        }

        self.sharedItems = items
        self.errorMessage = nil
        self.connectedClients = []
        self.transfers = []
        self.authorizedClients = []
        self.token = Self.randomHex(bytes: 12)
        self.pinCode = String(format: "%04d", Int.random(in: 1000...9999))

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwListener = try NWListener(using: params, on: .any)
            self.listener = nwListener

            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = nwListener.port?.rawValue {
                            let ip = Self.localWiFiIPv4() ?? "127.0.0.1"
                            let url = "http://\(ip):\(port)/s/\(self.token)"
                            self.shareURL = url
                            self.qrImage = Self.generateQRCode(for: url)
                            self.isRunning = true
                            self.expiresAt = Date().addingTimeInterval(ttlSeconds)
                            self.scheduleExpiry(ttlSeconds: ttlSeconds)
                        }
                    case .failed(let err):
                        self.errorMessage = "Share server failed: \(err.localizedDescription)"
                        self.stop()
                    default:
                        break
                    }
                }
            }

            let itemsSnapshot = items
            let sessionToken = self.token
            let sessionPin = self.pinCode
            let pinRequired = self.requirePin

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(
                    connection,
                    items: itemsSnapshot,
                    token: sessionToken,
                    pin: sessionPin,
                    pinRequired: pinRequired
                )
            }

            nwListener.start(queue: queue)
        } catch {
            errorMessage = "Could not start local share server: \(error.localizedDescription)"
        }
    }

    public func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        shareURL = ""
        qrImage = nil
        expiresAt = nil
        authorizedClients.removeAll()
    }

    private func scheduleExpiry(ttlSeconds: TimeInterval) {
        expiryTask?.cancel()
        expiryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(ttlSeconds * 1_000_000_000))
            if !Task.isCancelled {
                self.stop()
            }
        }
    }

    private nonisolated func handleConnection(
        _ connection: NWConnection,
        items: [MediaItem],
        token: String,
        pin: String,
        pinRequired: Bool
    ) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil,
                  let raw = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = raw.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                connection.cancel()
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let method = String(parts[0])
            let fullTarget = String(parts[1])
            let targetComponents = fullTarget.split(separator: "?", maxSplits: 1)
            let path = String(targetComponents[0])
            let query = targetComponents.count > 1 ? String(targetComponents[1]) : ""

            let clientIP: String
            if case .hostPort(let host, _) = connection.endpoint {
                clientIP = "\(host)"
            } else {
                clientIP = "Device"
            }

            // Parse cookies & Range header
            var cookieHeader = ""
            var rangeHeader: String?
            for line in lines.dropFirst() {
                if line.lowercased().hasPrefix("cookie:") {
                    cookieHeader = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                } else if line.lowercased().hasPrefix("range:") {
                    rangeHeader = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                }
            }

            let prefix = "/s/\(token)"
            guard path.hasPrefix(prefix) else {
                self.sendSimple(connection, status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8))
                return
            }

            // Only GET / HEAD / POST (PIN unlock) are permitted; never accept arbitrary uploads
            let sub = String(path.dropFirst(prefix.count))

            Task { @MainActor in
                if !self.connectedClients.contains(clientIP) {
                    self.connectedClients.append(clientIP)
                }
            }

            if sub == "/unlock" && method == "POST" {
                let bodyText = raw.components(separatedBy: "\r\n\r\n").last ?? ""
                let enteredPin = bodyText.replacingOccurrences(of: "pin=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if enteredPin == pin {
                    let resp = "HTTP/1.1 302 Found\r\nSet-Cookie: cs_pin=\(pin); Path=\(prefix); HttpOnly; SameSite=Strict\r\nLocation: \(prefix)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    let resp = "HTTP/1.1 302 Found\r\nLocation: \(prefix)?err=1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }

            let isAuthed = !pinRequired || cookieHeader.contains("cs_pin=\(pin)")
            if !isAuthed {
                let errFlag = query.contains("err=1")
                let html = Self.pinPageHTML(prefix: prefix, count: items.count, showError: errFlag)
                self.sendSimple(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
                return
            }

            if sub.isEmpty || sub == "/" {
                let html = Self.galleryHTML(prefix: prefix, items: items)
                self.sendSimple(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
                return
            }

            if sub.hasPrefix("/thumb/"), let idx = Int(sub.dropFirst(7)), items.indices.contains(idx) {
                let item = items[idx]
                Task {
                    if let img = await ThumbnailCache.shared.thumbnail(for: item, maxPixelSize: 420),
                       let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) {
                        self.sendSimple(connection, status: "200 OK", contentType: "image/jpeg", body: jpg)
                    } else {
                        self.sendSimple(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
                    }
                }
                return
            }

            if sub.hasPrefix("/file/"), let idx = Int(sub.dropFirst(6)), items.indices.contains(idx) {
                let item = items[idx]
                let forceDownload = query.contains("dl=1")
                self.streamFile(connection, item: item, clientIP: clientIP, rangeHeader: rangeHeader, forceDownload: forceDownload, headOnly: method == "HEAD")
                return
            }

            self.sendSimple(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private nonisolated func sendSimple(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated func streamFile(
        _ connection: NWConnection,
        item: MediaItem,
        clientIP: String,
        rangeHeader: String?,
        forceDownload: Bool,
        headOnly: Bool
    ) {
        guard let fh = try? FileHandle(forReadingFrom: item.url) else {
            sendSimple(connection, status: "404 Not Found", contentType: "text/plain", body: Data("File unavailable".utf8))
            return
        }
        let fileSize = item.fileSize
        var start: Int64 = 0
        var end: Int64 = max(0, fileSize - 1)
        var status = "200 OK"

        if let rh = rangeHeader, rh.hasPrefix("bytes=") {
            let parts = rh.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let s = Int64(parts[0]) { start = max(0, min(fileSize - 1, s)) }
            if parts.count > 1, let e = Int64(parts[1]) { end = max(start, min(fileSize - 1, e)) }
            status = "206 Partial Content"
        }

        let length = max(0, end - start + 1)
        let safeName = item.name.replacingOccurrences(of: "\"", with: "")
        var hdr = "HTTP/1.1 \(status)\r\n"
        hdr += "Content-Type: \(Self.mimeType(for: item))\r\n"
        hdr += "Content-Length: \(length)\r\n"
        hdr += "Accept-Ranges: bytes\r\n"
        if status.hasPrefix("206") {
            hdr += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        }
        if forceDownload {
            hdr += "Content-Disposition: attachment; filename=\"\(safeName)\"\r\n"
        }
        hdr += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"

        let transferID = UUID()
        Task { @MainActor in
            self.transfers.insert(
                ShareTransferRecord(clientAddress: clientIP, fileName: item.name, totalBytes: length, bytesSent: 0, isComplete: false, startedAt: Date()),
                at: 0
            )
        }

        let startOffset = UInt64(start)
        connection.send(content: Data(hdr.utf8), completion: .contentProcessed { err in
            if err != nil || headOnly || length == 0 {
                try? fh.close()
                connection.cancel()
                return
            }
            try? fh.seek(toOffset: startOffset)
            self.pumpFileChunks(connection: connection, fh: fh, remaining: length, sentSoFar: 0, fileName: item.name, clientIP: clientIP, transferID: transferID)
        })
    }

    private nonisolated func pumpFileChunks(
        connection: NWConnection,
        fh: FileHandle,
        remaining: Int64,
        sentSoFar: Int64,
        fileName: String,
        clientIP: String,
        transferID: UUID
    ) {
        if remaining <= 0 {
            try? fh.close()
            Task { @MainActor in
                if let idx = self.transfers.firstIndex(where: { $0.fileName == fileName && $0.clientAddress == clientIP && !$0.isComplete }) {
                    self.transfers[idx].bytesSent = self.transfers[idx].totalBytes
                    self.transfers[idx].isComplete = true
                }
            }
            connection.cancel()
            return
        }

        let chunkSize = Int(min(remaining, 512 * 1024)) // 512 KB chunks for low RAM & fast Wi-Fi
        let data = (try? fh.read(upToCount: chunkSize)) ?? Data()
        if data.isEmpty {
            try? fh.close()
            connection.cancel()
            return
        }

        let nextSent = sentSoFar + Int64(data.count)
        let nextRemaining = remaining - Int64(data.count)

        connection.send(content: data, completion: .contentProcessed { err in
            if err != nil {
                try? fh.close()
                connection.cancel()
                return
            }
            Task { @MainActor in
                if let idx = self.transfers.firstIndex(where: { $0.fileName == fileName && $0.clientAddress == clientIP && !$0.isComplete }) {
                    self.transfers[idx].bytesSent = nextSent
                }
            }
            self.pumpFileChunks(connection: connection, fh: fh, remaining: nextRemaining, sentSoFar: nextSent, fileName: fileName, clientIP: clientIP, transferID: transferID)
        })
    }

    // MARK: - Core Image QR Generator & Network Helpers

    public static func generateQRCode(for string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }

    public static func localWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let utf8Bytes = hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    let ip = String(decoding: utf8Bytes, as: UTF8.self)
                    let name = String(cString: current.pointee.ifa_name)
                    if name == "en0" { return ip }
                    if fallback == nil { fallback = ip }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return fallback
    }

    private static func randomHex(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func mimeType(for item: MediaItem) -> String {
        switch item.kind {
        case .video: return "video/mp4"
        case .audio: return "audio/mpeg"
        case .pdf: return "application/pdf"
        case .textFile: return "application/octet-stream"
        case .image:
            switch item.fileExtension.lowercased() {
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            default: return "image/jpeg"
            }
        }
    }

    private nonisolated static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private nonisolated static func pinPageHTML(prefix: String, count: Int, showError: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>ChronoStream Share</title>
        <style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:20px}
        .card{width:100%;max-width:340px;background:#fff;border-radius:18px;padding:26px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center}
        h1{font-size:20px;margin:0 0 6px}p{font-size:14px;color:#6e6e73;margin:0 0 18px}
        input{width:100%;box-sizing:border-box;padding:12px;font-size:24px;letter-spacing:8px;text-align:center;border:1px solid #d2d2d7;border-radius:12px;margin-bottom:14px}
        button{width:100%;padding:12px;border:none;border-radius:12px;background:#007aff;color:#fff;font-size:15px;font-weight:600}
        .err{color:#d70015;font-size:13px;margin-bottom:10px}
        </style></head><body>
        <form class="card" method="POST" action="\(prefix)/unlock">
        <h1>ChronoStream Share</h1>
        <p>Enter the 4-digit PIN shown on your Mac to access \(count) file\(count == 1 ? "" : "s").</p>
        \(showError ? "<div class=\"err\">Incorrect PIN. Please try again.</div>" : "")
        <input name="pin" type="tel" inputmode="numeric" maxlength="4" pattern="[0-9]{4}" placeholder="••••" autofocus required />
        <button type="submit">Continue</button>
        </form></body></html>
        """
    }

    private nonisolated static func galleryHTML(prefix: String, items: [MediaItem]) -> String {
        let cards = items.enumerated().map { idx, item in
            let safeName = escapeHTML(item.name)
            let sizeText = MediaFormatting.byteString(item.fileSize)
            return """
            <div class="card">
              <img src="\(prefix)/thumb/\(idx)" alt="\(safeName)" loading="lazy" />
              <div class="meta">
                <div class="info">
                  <div class="name">\(safeName)</div>
                  <div class="sub">\(item.kind.displayName) · \(sizeText)</div>
                </div>
                <a class="dl" href="\(prefix)/file/\(idx)?dl=1" download="\(safeName)">Download</a>
              </div>
            </div>
            """
        }.joined()

        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>ChronoStream Share</title>
        <style>
        body{margin:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:18px}
        header{max-width:720px;margin:0 auto 18px;display:flex;justify-content:space-between;align-items:baseline}
        h1{font-size:22px;margin:0}span.count{font-size:13px;color:#6e6e73}
        .grid{max-width:720px;margin:0 auto;display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
        .card{background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 4px 16px rgba(0,0,0,.06)}
        .card img{width:100%;aspect-ratio:16/9;object-fit:cover;background:#e5e5ea;display:block}
        .meta{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:12px 14px}
        .info{min-width:0}.name{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .sub{font-size:12px;color:#6e6e73;margin-top:2px}
        .dl{flex-shrink:0;background:#007aff;color:#fff;text-decoration:none;padding:8px 14px;border-radius:999px;font-size:13px;font-weight:600}
        </style></head><body>
        <header><h1>Shared from Mac</h1><span class="count">\(items.count) item\(items.count == 1 ? "" : "s")</span></header>
        <div class="grid">\(cards)</div>
        </body></html>
        """
    }
}
