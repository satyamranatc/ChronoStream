import Foundation
import UniformTypeIdentifiers

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case video
    case audio
    case image
    case pdf

    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Photo"
        case .pdf: return "Document"
        }
    }

    public var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        }
    }
}

public enum ContainerCompatibility: String, Sendable {
    case nativeAVFoundation = "Native AVFoundation (Hardware Accelerated)"
    case ffmpegRemux = "FFmpeg Remux Fallback"
    case nativeImageIO = "Native ImageIO / CGImageSource"
    case nativePDFKit = "Native PDFKit"
    case unsupported = "Unsupported or Corrupted"
}

public enum MediaFormatRegistry {
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "mts", "mpg", "mpeg"]
    public static let audioExtensions: Set<String> = ["mp3", "wav", "aac", "m4a", "flac", "alac", "aiff", "ogg", "opus"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp", "dng", "cr2", "nef", "arw"]
    public static let documentExtensions: Set<String> = ["pdf"]

    public static let allSupportedExtensions: Set<String> =
        videoExtensions.union(audioExtensions).union(imageExtensions).union(documentExtensions)

    public static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        if documentExtensions.contains(ext) { return .pdf }
        return nil
    }

    /// Inspects file magic bytes safely (treating files as untrusted input) to determine container compatibility.
    public static func inspectCompatibility(for url: URL) -> ContainerCompatibility {
        guard let kind = kind(for: url) else { return .unsupported }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .unsupported }
        defer { try? fh.close() }

        let header = (try? fh.read(upToCount: 16)) ?? Data()
        guard header.count >= 4 else { return .unsupported }
        let bytes = [UInt8](header)

        switch kind {
        case .pdf:
            // %PDF-
            if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 {
                return .nativePDFKit
            }
            return .unsupported

        case .image:
            // JPEG, PNG, GIF, TIFF, WebP, HEIC/ftyp, BMP
            let isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8
            let isPng = bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
            let isGif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46
            let isTiff = (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D)
            let isRiff = bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            let isBmp = bytes[0] == 0x42 && bytes[1] == 0x4D
            let isFtyp = bytes.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
            return (isJpeg || isPng || isGif || isTiff || isRiff || isBmp || isFtyp) ? .nativeImageIO : .unsupported

        case .audio:
            let ext = url.pathExtension.lowercased()
            if ext == "ogg" || ext == "opus" {
                return .ffmpegRemux
            }
            return .nativeAVFoundation

        case .video:
            // Standard ISO BMFF MP4 / MOV ('ftyp' or 'moov' or 'mdat' at offset 4)
            if bytes.count >= 8 {
                let atom = String(bytes: bytes[4..<8], encoding: .ascii)
                if atom == "ftyp" || atom == "moov" || atom == "wide" || atom == "free" {
                    return .nativeAVFoundation
                }
            }
            // MPEG-PS (e.g. Hikvision DVR .mp4 starting with 00 00 01 BA)
            if bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x01 && bytes[3] == 0xBA {
                return .ffmpegRemux
            }
            // Matroska / WebM (1A 45 DF A3)
            if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
                return .ffmpegRemux
            }
            // AVI (RIFF....AVI )
            if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
                return .ffmpegRemux
            }
            // MPEG-TS sync byte
            if bytes[0] == 0x47 {
                return .ffmpegRemux
            }
            return .unsupported
        }
    }
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String // Canonical standardized file path
    public let path: String
    public let name: String
    public let kind: MediaKind
    public let fileSize: Int64
    public let modifiedDate: Date
    public var duration: Double?
    public var isFavorite: Bool
    public var lastPosition: Double
    public var lastOpened: Date?
    public var partialHash: String?

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileExtension: String { url.pathExtension.uppercased() }

    public init(
        url: URL,
        kind: MediaKind,
        fileSize: Int64,
        modifiedDate: Date,
        duration: Double? = nil,
        isFavorite: Bool = false,
        lastPosition: Double = 0,
        lastOpened: Date? = nil,
        partialHash: String? = nil
    ) {
        let std = url.standardizedFileURL.path
        self.id = std
        self.path = std
        self.name = url.lastPathComponent
        self.kind = kind
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.duration = duration
        self.isFavorite = isFavorite
        self.lastPosition = lastPosition
        self.lastOpened = lastOpened
        self.partialHash = partialHash
    }
}

public struct CustomCollection: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var symbol: String
    public var itemIDs: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, symbol: String = "folder", itemIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }
}

public struct AuthorizedFolder: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let bookmarkData: Data?

    public var url: URL { URL(fileURLWithPath: path) }

    public init(url: URL, bookmarkData: Data?) {
        let std = url.standardizedFileURL.path
        self.id = std
        self.path = std
        self.name = url.lastPathComponent
        self.bookmarkData = bookmarkData
    }
}

public enum SidebarSelection: Hashable, Sendable {
    case dashboard
    case smart(SmartCollection)
    case folder(String)
    case collection(UUID)
    case photoStudio
    case videoStudio
    case documentStudio
}

public enum SmartCollection: String, CaseIterable, Identifiable, Sendable {
    case all = "All Media"
    case continueWatching = "Continue"
    case videos = "Videos"
    case audio = "Music & Audio"
    case photos = "Photos"
    case documents = "PDF Documents"
    case favorites = "Favorites"
    case recent = "Recently Opened"
    case duplicates = "Duplicates"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .continueWatching: return "play.circle"
        case .videos: return "film"
        case .audio: return "music.note"
        case .photos: return "photo.on.rectangle"
        case .documents: return "doc.richtext"
        case .favorites: return "heart"
        case .recent: return "clock"
        case .duplicates: return "doc.on.doc"
        }
    }
}

public enum ExplorerViewMode: String, CaseIterable, Identifiable, Sendable {
    case grid = "Grid"
    case list = "List"

    public var id: String { rawValue }
    public var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

public enum MediaSortOrder: String, CaseIterable, Identifiable, Sendable {
    case nameAsc = "Name (A–Z)"
    case dateDesc = "Newest First"
    case sizeDesc = "Largest First"
    case kind = "Type"

    public var id: String { rawValue }
}

public enum MediaFormatting {
    public static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    public static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
