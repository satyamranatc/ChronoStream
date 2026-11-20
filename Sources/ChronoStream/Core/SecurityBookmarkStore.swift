import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum DefaultAppManager {
    public static var videoTypes: [UTType] {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie]
        for ext in ["m4v", "mkv", "avi", "webm"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }

    public static func isDefaultForMP4() -> Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: .mpeg4Movie) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    @MainActor
    public static func setAsDefaultVideoPlayer() async -> Bool {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return false }
        var anySucceeded = false
        for type in videoTypes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                anySucceeded = true
            } catch {}
        }
        return anySucceeded
    }
}

/// Persists library state, security-scoped folder bookmarks, playback positions, favorites, and collections.
public struct PersistedLibraryState: Codable, Sendable {
    public var folders: [AuthorizedFolder] = []
    public var collections: [CustomCollection] = []
    public var favorites: Set<String> = []
    public var playbackPositions: [String: Double] = [:]
    public var lastOpenedDates: [String: Date] = [:]
    public var monitorFoldersEnabled: Bool = false
    public var slideshowInterval: Double = 4.0
    public var defaultPlaybackRate: Double = 1.0

    public init() {}
}

public final class SecurityBookmarkStore: @unchecked Sendable {
    public static let shared = SecurityBookmarkStore()

    private let appSupportURL: URL
    private let stateFileURL: URL
    private var activeScopedURLs: [String: URL] = [:]
    private let lock = NSLock()

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.appSupportURL = base.appendingPathComponent("ChronoStream", isDirectory: true)
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        self.stateFileURL = appSupportURL.appendingPathComponent("library.json")
    }

    public func loadState() -> PersistedLibraryState {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return PersistedLibraryState()
        }
        return (try? JSONDecoder().decode(PersistedLibraryState.self, from: data)) ?? PersistedLibraryState()
    }

    public func saveState(_ state: PersistedLibraryState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    public func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveAndStartAccess(folder: AuthorizedFolder) -> URL {
        lock.lock()
        defer { lock.unlock() }

        if let existing = activeScopedURLs[folder.id] {
            return existing
        }

        if let data = folder.bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                activeScopedURLs[folder.id] = resolved
                return resolved
            }
        }

        return folder.url
    }

    public func stopAccess(for folderID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let url = activeScopedURLs.removeValue(forKey: folderID) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Computes a fast partial SHA-256 (first 64 KB + last 64 KB + size) for duplicate detection without reading gigabytes.
    public static func fastPartialHash(for url: URL, fileSize: Int64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        var hasher = SHA256()
        var sizeLE = fileSize.littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(bufferPointer: $0) }

        let chunk = 65_536
        if let head = try? fh.read(upToCount: chunk) {
            hasher.update(data: head)
        }
        if fileSize > Int64(chunk * 2) {
            try? fh.seek(toOffset: UInt64(fileSize - Int64(chunk)))
            if let tail = try? fh.read(upToCount: chunk) {
                hasher.update(data: tail)
            }
        }
        let digest = hasher.finalize()
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
