# Security Policy

## Supported Versions

| Version | Supported |
| :--- | :--- |
| 2.0.x | Yes |

## Security Model

- **Offline-First**: ChronoStream does not require accounts, telemetry, or cloud uploads.
- **Least-Privilege File Access**: Folder access is granted explicitly by the user via macOS Open Panels and persisted using Security-Scoped Bookmarks.
- **Local Wi-Fi QR Sharing**: The built-in `NWListener` HTTP server binds ephemerally on the local LAN only, requires a random 24-character session token and 4-digit PIN, and automatically shuts down after 10 minutes or when the share sheet is closed.

## Reporting a Vulnerability

If you discover a security vulnerability, please do **not** open a public issue. Email **satyamranatc@gmail.com** with reproduction steps and affected version details. You can expect an initial response within 72 hours.
