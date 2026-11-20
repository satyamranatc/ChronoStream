# Changelog

All notable changes to **ChronoStream** are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-11-21

### Added
- **Unified Native macOS Suite**: Rebuilt from the ground up in Swift 6 / SwiftUI for Apple Silicon (`arm64`, macOS 14+).
- **Video Player**:
  - Hardware-accelerated `AVPlayer` with Precision Zoom timeline (`Full` / `1 hr` / `15m` / `2m`) for 12–24+ hour recordings.
  - Persistent `ScrubPreviewEngine` with 40-frame pre-warmed filmstrip cache and latest-wins live keyframe decoding for instant seek-bar hover previews.
  - Full keyboard shortcut suite (`Space`/`K`, `←`/`→`, `⇧←`/`⇧→`, `J`/`L`, `,`/`.`, `0`–`9`, `[`/`]`, `↑`/`↓`, `M`, `F`, `Z`, `C`, `Esc`, `?`) with on-screen feedback pill and cheat-sheet popover.
  - External `.srt` / `.vtt` subtitle parser and overlay.
  - Automatic magic-byte detection and transparent FFmpeg remuxing for Hikvision MPEG-PS, `.mkv`, `.avi`, and `.webm`.
- **Music Player**: Two-column studio layout with ambient artwork glow, 28-bar `AudioSpectrumCanvas`, 3-state repeat, `-15s`/`+15s` skip, Sleep Timer, playback speed, and searchable Up Next queue.
- **Doc Writer**: Native rich-text word processor with Microsoft Word `.docx` save/open (`officeOpenXML`), Saved Documents panel, live-synced formatting ribbon, native tables, teaching callouts, code blocks, Teach Mode, and A4 PDF export.
- **Photo & Video Studios**: Image crop/text/adjustments, Collage & GIF maker, plus FFmpeg-powered trim, crop/speed/rotate, merge, audio swap, and audio extraction.
- **Cross-Platform Share Sheet**: Native macOS AirDrop / Share Sheet plus ephemeral PIN-protected local Wi-Fi QR transfer (`NWListener` + `CIQRCodeGenerator`).
- **Dashboard & Library**: Animated hero banner, library stats, storage breakdown, Continue Watching, Smart & Custom Collections, partial SHA-256 duplicate detection, and Default Video Player integration.

### Fixed
- Eliminated video freezes and stale playback when rapidly switching videos or pressing Back via monotonic `loadGeneration` guards and non-blocking async FFmpeg process execution.
- Fixed missing bottom thumbnails in large folders with bounded concurrency and cancellation-safe lazy loading.
- Polished macOS sidebar layering, section header `+` buttons, and instant tab switching.
