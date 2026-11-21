import AppKit
import Foundation
import Network
import Observation

public struct ReceivedWiFiFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let fileSize: Int64
    public let receivedAt: Date
}

/// Thread-safe security gate for local Wi-Fi uploads:
/// enforces a random 24-char URL session token, a 4-digit PIN, and brute-force lockout (5 fails -> 60s lock).
private final class ReceiveSecurityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String = ""
    private var pin: String = ""
    private var failedAttempts: Int = 0
    private var lockedUntil: Date?

    func configure(token: String, pin: String) {
        lock.lock()
        self.token = token
        self.pin = pin
        self.failedAttempts = 0
        self.lockedUntil = nil
        lock.unlock()
    }

    func updatePIN(_ newPIN: String) {
        lock.lock()
        self.pin = newPIN
        self.failedAttempts = 0
        self.lockedUntil = nil
        lock.unlock()
    }

    func matchesToken(_ candidate: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !token.isEmpty && candidate == token
    }

    enum PINCheckResult: Sendable {
        case valid
        case invalid(remainingAttempts: Int)
        case locked(secondsLeft: Int)
    }

    func verifyPIN(_ candidate: String?) -> PINCheckResult {
        lock.lock()
        defer { lock.unlock() }

        if let until = lockedUntil {
            let left = Int(ceil(until.timeIntervalSinceNow))
            if left > 0 {
                return .locked(secondsLeft: left)
            } else {
                lockedUntil = nil
                failedAttempts = 0
            }
        }

        if let candidate, !pin.isEmpty, candidate == pin {
            failedAttempts = 0
            return .valid
        }

        failedAttempts += 1
        if failedAttempts >= 5 {
            lockedUntil = Date().addingTimeInterval(60)
            return .locked(secondsLeft: 60)
        }
        return .invalid(remainingAttempts: max(0, 5 - failedAttempts))
    }

    func isAuthorized(pin candidate: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let until = lockedUntil, until > Date() { return false }
        return candidate != nil && !pin.isEmpty && candidate == pin
    }
}

/// Ephemeral, security-hardened local Wi-Fi receiver (Android / iPhone -> Mac).
/// Uses a random 24-char session token, 4-digit PIN with lockout, and 10-minute auto-expiry.
@MainActor
@Observable
public final class SecureWiFiReceiver {
    public var isRunning: Bool = false
    public var receiverURL: String?
    public var qrImage: NSImage?
    public var securityPIN: String = ""
    public var secondsRemaining: Int = 600
    public var statusMessage: String?
    public var errorMessage: String?
    public var receivedFiles: [ReceivedWiFiFile] = []

    public nonisolated static let inboxDirectory: URL = {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let dir = dl.appendingPathComponent("ChronoStream Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let securityGate = ReceiveSecurityGate()
    private var listener: NWListener?
    private var expiryTimer: Timer?
    private let serverQueue = DispatchQueue(label: "com.chronostream.securewifi.receive", qos: .userInitiated)

    public init() {
        loadExistingInbox()
    }

    public func loadExistingInbox() {
        let dir = Self.inboxDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        receivedFiles = urls.compactMap { url -> ReceivedWiFiFile? in
            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return ReceivedWiFiFile(
                url: url,
                name: url.lastPathComponent,
                fileSize: Int64(vals?.fileSize ?? 0),
                receivedAt: vals?.creationDate ?? Date()
            )
        }
        .sorted { $0.receivedAt > $1.receivedAt }
    }

    public func rotatePIN() {
        let newPIN = String(format: "%04d", Int.random(in: 1000...9999))
        securityPIN = newPIN
        securityGate.updatePIN(newPIN)
    }

    public func start() {
        stop()
        errorMessage = nil

        guard let ip = LocalShareSession.localWiFiIPv4() else {
            errorMessage = "Connect this Mac to Wi-Fi first."
            return
        }

        let token = Self.randomToken(length: 24)
        let pin = String(format: "%04d", Int.random(in: 1000...9999))
        securityPIN = pin
        securityGate.configure(token: token, pin: pin)
        secondsRemaining = 600

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: .any)

            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = l.port?.rawValue {
                            let url = "http://\(ip):\(port)/r/\(token)"
                            self.receiverURL = url
                            self.qrImage = LocalShareSession.generateQRCode(for: url)
                            self.isRunning = true
                            self.statusMessage = "Secure session active · auto-expires in 10 min"
                            self.startExpiryTimer()
                        }
                    case .failed(let err):
                        self.errorMessage = "Receiver error: \(err.localizedDescription)"
                        self.stop()
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }

            l.start(queue: serverQueue)
            self.listener = l
        } catch {
            errorMessage = "Could not start secure receiver: \(error.localizedDescription)"
        }
    }

    public func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        receiverURL = nil
        qrImage = nil
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if self.secondsRemaining > 1 {
                    self.secondsRemaining -= 1
                } else {
                    self.stop()
                    self.statusMessage = "Session auto-expired for security. Click Start Session to receive again."
                }
            }
        }
    }

    // MARK: - HTTP Request Handling (off MainActor)

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        readHeaders(connection: connection, buffer: Data())
    }

    private nonisolated func readHeaders(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }
            var acc = buffer
            if let data { acc.append(data) }

            let sep = Data("\r\n\r\n".utf8)
            if let range = acc.range(of: sep) {
                let headerData = acc.subdata(in: 0..<range.lowerBound)
                let bodyRemainder = acc.subdata(in: range.upperBound..<acc.count)
                self.dispatchRequest(connection: connection, headerData: headerData, initialBody: bodyRemainder)
            } else if isComplete || acc.count > 65536 {
                connection.cancel()
            } else {
                self.readHeaders(connection: connection, buffer: acc)
            }
        }
    }

    private nonisolated func dispatchRequest(connection: NWConnection, headerData: Data, initialBody: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var contentLength: Int64 = 0
        var headerPIN: String?
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if k == "content-length", let n = Int64(v) {
                    contentLength = n
                } else if k == "x-chrono-pin" {
                    headerPIN = v
                }
            }
        }

        let comps = URLComponents(string: "http://localhost\(rawTarget)")
        let path = comps?.path ?? rawTarget

        // All routes MUST carry the random 24-char session token: /r/<token>
        guard path.hasPrefix("/r/") else {
            sendResponse(connection: connection, status: "403 Forbidden", contentType: "text/plain", body: Data("Invalid session link".utf8))
            return
        }
        let subPath = String(path.dropFirst(3))
        let segs = subPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let tokenSeg = segs.first, securityGate.matchesToken(String(tokenSeg)) else {
            sendResponse(connection: connection, status: "403 Forbidden", contentType: "text/plain", body: Data("Session expired or invalid token".utf8))
            return
        }
        let tokenStr = String(tokenSeg)
        let action = segs.count > 1 ? String(segs[1]) : ""

        if method == "GET" && action.isEmpty {
            let html = Self.mobilePortalHTML(basePath: "/r/\(tokenStr)")
            sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
            return
        }

        if method == "GET" && action == "verify" {
            let qPIN = comps?.queryItems?.first(where: { $0.name == "pin" })?.value ?? headerPIN
            switch securityGate.verifyPIN(qPIN) {
            case .valid:
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            case .invalid(let rem):
                sendResponse(connection: connection, status: "403 Forbidden", contentType: "application/json", body: Data("{\"ok\":false,\"error\":\"Incorrect PIN (\(rem) tries left)\"}".utf8))
            case .locked(let secs):
                sendResponse(connection: connection, status: "429 Too Many Requests", contentType: "application/json", body: Data("{\"ok\":false,\"error\":\"Too many attempts. Locked for \(secs)s.\"}".utf8))
            }
            return
        }

        if method == "POST" && action == "upload" {
            let qPIN = comps?.queryItems?.first(where: { $0.name == "pin" })?.value ?? headerPIN
            guard securityGate.isAuthorized(pin: qPIN) else {
                sendResponse(connection: connection, status: "403 Forbidden", contentType: "application/json", body: Data("{\"ok\":false,\"error\":\"PIN required\"}".utf8))
                return
            }
            let rawName = comps?.queryItems?.first(where: { $0.name == "name" })?.value ?? "PhoneFile-\(Int(Date().timeIntervalSince1970))"
            let safeName = Self.sanitizeFileName(rawName)
            let destURL = Self.uniqueInboxURL(fileName: safeName)

            FileManager.default.createFile(atPath: destURL.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: destURL) else {
                sendResponse(connection: connection, status: "500 Internal Server Error", contentType: "application/json", body: Data("{\"ok\":false}".utf8))
                return
            }

            if !initialBody.isEmpty {
                try? fh.write(contentsOf: initialBody)
            }
            let remaining = max(0, contentLength - Int64(initialBody.count))
            streamUploadBody(connection: connection, fh: fh, destURL: destURL, remaining: remaining, totalBytes: contentLength)
            return
        }

        sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
    }

    private nonisolated func streamUploadBody(
        connection: NWConnection,
        fh: FileHandle,
        destURL: URL,
        remaining: Int64,
        totalBytes: Int64
    ) {
        if remaining <= 0 {
            try? fh.close()
            let fileName = destURL.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? totalBytes
            let record = ReceivedWiFiFile(url: destURL, name: fileName, fileSize: size, receivedAt: Date())
            Task { @MainActor in
                self.receivedFiles.insert(record, at: 0)
                self.statusMessage = "Received \(fileName) (\(MediaFormatting.byteString(size)))"
            }
            sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            return
        }

        let toRead = Int(min(remaining, 256 * 1024))
        connection.receive(minimumIncompleteLength: 1, maximumLength: toRead) { [weak self] data, _, isComplete, error in
            guard let self else {
                try? fh.close()
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                try? fh.write(contentsOf: data)
                let nextRemaining = remaining - Int64(data.count)
                if nextRemaining <= 0 || isComplete {
                    self.streamUploadBody(connection: connection, fh: fh, destURL: destURL, remaining: 0, totalBytes: totalBytes)
                } else {
                    self.streamUploadBody(connection: connection, fh: fh, destURL: destURL, remaining: nextRemaining, totalBytes: totalBytes)
                }
            } else if error != nil || isComplete {
                try? fh.close()
                self.sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            }
        }
    }

    private nonisolated func sendResponse(connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated static func randomToken(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private nonisolated static func sanitizeFileName(_ raw: String) -> String {
        let base = URL(fileURLWithPath: raw).lastPathComponent
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let clean = base.components(separatedBy: bad).joined(separator: "_")
        return clean.isEmpty ? "PhoneUpload-\(Int(Date().timeIntervalSince1970))" : clean
    }

    private nonisolated static func uniqueInboxURL(fileName: String) -> URL {
        let dir = inboxDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var candidate = dir.appendingPathComponent(fileName)
        var counter = 2
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = dir.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }

    private nonisolated static func mobilePortalHTML(basePath: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1" />
          <title>ChronoStream · Secure Wi-Fi Send</title>
          <style>
            * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
            body { margin: 0; background: #F7FAFA; color: #0F172A; min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; }
            .card { width: 100%; max-width: 440px; background: #FFFFFF; border: 1px solid #E2E8F0; border-radius: 20px; padding: 26px 22px; box-shadow: 0 12px 32px rgba(15,23,42,0.06); }
            .badge { display: inline-block; font-size: 11px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: #008080; background: #E6F4F4; padding: 4px 10px; border-radius: 999px; margin-bottom: 10px; }
            h1 { margin: 0 0 6px; font-size: 22px; }
            p { margin: 0 0 18px; color: #475569; font-size: 14px; line-height: 1.5; }
            .drop { display: block; width: 100%; border: 2px dashed #99D5D5; background: #F3FAFA; border-radius: 16px; padding: 28px 16px; text-align: center; cursor: pointer; }
            .drop strong { display: block; color: #006666; font-size: 16px; margin-bottom: 4px; }
            .drop span { font-size: 12px; color: #64748B; }
            input[type=file] { display: none; }
            .pin-box { display: flex; gap: 8px; margin-bottom: 10px; }
            .pin-input { flex: 1; font-size: 22px; letter-spacing: 6px; text-align: center; padding: 12px; border: 1.5px solid #CBD5E1; border-radius: 12px; outline: none; }
            .pin-input:focus { border-color: #008080; }
            .btn { background: #008080; color: #fff; border: 0; border-radius: 12px; padding: 0 20px; font-size: 15px; font-weight: 600; cursor: pointer; }
            .hidden { display: none; }
            .list { margin-top: 18px; display: flex; flex-direction: column; gap: 10px; }
            .row { background: #F8FAFC; border: 1px solid #E2E8F0; border-radius: 12px; padding: 10px 12px; font-size: 13px; }
            .row-top { display: flex; justify-content: space-between; gap: 8px; margin-bottom: 6px; font-weight: 600; }
            .bar-bg { height: 6px; background: #E2E8F0; border-radius: 999px; overflow: hidden; }
            .bar { height: 100%; width: 0%; background: #008080; transition: width .12s; }
            .done { color: #059669; }
            .err { color: #DC2626; }
          </style>
        </head>
        <body>
          <div class="card">
            <div class="badge">Same Wi-Fi · Token + PIN Protected</div>
            <h1>Send to Mac</h1>
            <div id="lockScreen">
              <p>Enter the 4-digit security PIN displayed in ChronoStream on your Mac.</p>
              <div class="pin-box">
                <input id="pinInput" class="pin-input" type="tel" inputmode="numeric" maxlength="4" placeholder="••••" />
                <button id="unlockBtn" class="btn">Unlock</button>
              </div>
              <div id="pinErr" class="err" style="font-size:13px;min-height:18px;"></div>
            </div>
            <div id="uploadScreen" class="hidden">
              <p>Unlocked. Choose photos, videos, audio, or PDFs — transferred directly over your local Wi-Fi with zero cloud servers.</p>
              <label class="drop">
                <input id="picker" type="file" multiple />
                <strong>Tap to Choose Files</strong>
                <span>Photos, Videos, Recordings, Music, PDFs</span>
              </label>
              <div id="list" class="list"></div>
            </div>
          </div>
          <script>
            const BASE = '\(basePath)';
            let verifiedPIN = '';
            const pinInput = document.getElementById('pinInput');
            const unlockBtn = document.getElementById('unlockBtn');
            const pinErr = document.getElementById('pinErr');
            const lockScreen = document.getElementById('lockScreen');
            const uploadScreen = document.getElementById('uploadScreen');
            const picker = document.getElementById('picker');
            const list = document.getElementById('list');

            async function tryUnlock() {
              const code = pinInput.value.trim();
              if (code.length !== 4) { pinErr.textContent = 'Enter all 4 digits.'; return; }
              pinErr.textContent = '';
              try {
                const res = await fetch(BASE + '/verify?pin=' + encodeURIComponent(code));
                const data = await res.json().catch(() => ({}));
                if (res.ok && data.ok) {
                  verifiedPIN = code;
                  lockScreen.classList.add('hidden');
                  uploadScreen.classList.remove('hidden');
                } else {
                  pinErr.textContent = data.error || 'Incorrect PIN.';
                }
              } catch {
                pinErr.textContent = 'Could not reach Mac. Check Wi-Fi.';
              }
            }
            unlockBtn.addEventListener('click', tryUnlock);
            pinInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') tryUnlock(); });

            picker.addEventListener('change', async () => {
              for (const file of picker.files) {
                const row = document.createElement('div');
                row.className = 'row';
                row.innerHTML = `<div class="row-top"><span>${file.name}</span><span class="pct">0%</span></div><div class="bar-bg"><div class="bar"></div></div>`;
                list.prepend(row);
                const pct = row.querySelector('.pct');
                const bar = row.querySelector('.bar');
                await new Promise((resolve) => {
                  const xhr = new XMLHttpRequest();
                  xhr.open('POST', BASE + '/upload?name=' + encodeURIComponent(file.name) + '&pin=' + encodeURIComponent(verifiedPIN));
                  xhr.setRequestHeader('X-Chrono-PIN', verifiedPIN);
                  xhr.upload.onprogress = (e) => {
                    if (e.lengthComputable) {
                      const p = Math.round((e.loaded / e.total) * 100);
                      pct.textContent = p + '%';
                      bar.style.width = p + '%';
                    }
                  };
                  xhr.onload = () => {
                    if (xhr.status === 200) {
                      pct.textContent = 'Sent';
                      pct.className = 'pct done';
                      bar.style.width = '100%';
                    } else if (xhr.status === 403) {
                      pct.textContent = 'PIN Expired';
                      pct.className = 'pct err';
                    } else {
                      pct.textContent = 'Failed';
                      pct.className = 'pct err';
                    }
                    resolve();
                  };
                  xhr.onerror = () => {
                    pct.textContent = 'Network Error';
                    pct.className = 'pct err';
                    resolve();
                  };
                  xhr.send(file);
                });
              }
              picker.value = '';
            });
          </script>
        </body>
        </html>
        """
    }
}
