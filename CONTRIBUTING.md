# Contributing to ChronoStream

Thank you for your interest in improving ChronoStream.

## Development Workflow

1. Fork the repository and create a topic branch from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. Build and verify locally in release mode before opening a pull request:
   ```bash
   swift build -c release
   ```
3. Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages:
   - `feat:` for new features
   - `fix:` for bug fixes
   - `perf:` for performance improvements
   - `docs:` for documentation updates
   - `chore:` for tooling or build changes

## Code Standards

- Prefer Apple's native frameworks (`AVFoundation`, `AppKit`, `SwiftUI`, `Network`, `CoreImage`, `PDFKit`, `ImageIO`) over third-party dependencies.
- Keep main-thread work strictly minimal: file I/O, hashing, thumbnail extraction, and FFmpeg processes must execute off `@MainActor`.
- Maintain Swift 6 strict concurrency safety without introducing data races.
