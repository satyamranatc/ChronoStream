import AppKit
import SwiftUI

private struct OnboardingSlide: Identifiable {
    let id: Int
    let badge: String
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    let highlights: [(symbol: String, title: String, detail: String)]
}

/// Interactive multi-slide First-Time Welcome Tour with smooth transitions and a clear Start button.
public struct WelcomeView: View {
    let onAddFolder: () -> Void
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentIndex: Int = 0
    @State private var slideDirection: Int = 1

    public init(onAddFolder: @escaping () -> Void, onContinue: @escaping () -> Void) {
        self.onAddFolder = onAddFolder
        self.onContinue = onContinue
    }

    private let slides: [OnboardingSlide] = [
        OnboardingSlide(
            id: 0,
            badge: "SEAMLESS EXPERIENCE",
            title: "Welcome to ChronoStream",
            subtitle: "One fast, calm, offline-first workspace designed to bring all your everyday media and documents together.",
            symbol: "sparkles.rectangle.stack",
            accent: Color(red: 0.0, green: 0.478, blue: 1.0),
            highlights: [
                ("bolt.fill", "Fast, Calm & Native", "Instant startup, smooth playback for long 12–24+ hour videos, and Pure Light & Dark themes."),
                ("arrow.uturn.backward.circle", "Zero Friction Navigation", "Exact scroll preservation when returning from any video, with your last played item highlighted."),
                ("display.2", "AirPlay & External HDMI Ready", "Cast to TVs or switch into full-screen HDMI Cinema mode with one click.")
            ]
        ),
        OnboardingSlide(
            id: 1,
            badge: "MANAGE EVERYTHING",
            title: "All Your Media in One Place",
            subtitle: "Browse, organize, and manage videos, music, photos, PDFs, and Word documents effortlessly.",
            symbol: "folder.badge.gearshape",
            accent: Color(red: 0.0, green: 0.478, blue: 1.0),
            highlights: [
                ("cursorarrow.click.2", "Finder-Style Controls", "Single-click to select, navigate with arrow keys, double-click or press Return to play."),
                ("doc.on.doc", "Cut, Copy, Paste, Rename & Drag-Drop", "Full right-click file actions and direct drag-and-drop to Finder, Desktop, or sidebar folders."),
                ("scissors", "Built-In Photo & Video Studios", "Crop, annotate, build collages, or trim, merge, and extract audio without leaving the app.")
            ]
        ),
        OnboardingSlide(
            id: 2,
            badge: "READ & WRITE",
            title: "Read PDFs & Books Comfortably",
            subtitle: "A distraction-free PDF book reader and native Microsoft Word (.docx) writer built right in.",
            symbol: "book.pages",
            accent: Color(red: 0.0, green: 0.478, blue: 1.0),
            highlights: [
                ("paintpalette", "4 Calm Reading Themes", "Switch between Paper, Sepia, Soft Gray, and Night mode with Two-Page Book Spread."),
                ("bookmark", "Chapters, Bookmarks & Study Notes", "Jump via Table of Contents, bookmark key pages, and save page-linked notes with auto-resume."),
                ("doc.text.fill", "Native Word (.docx) & PDF Export", "Write clean documents with headings, tables, and Teach Mode — save as .docx or A4 PDF.")
            ]
        ),
        OnboardingSlide(
            id: 3,
            badge: "ONE-CLICK SHARE",
            title: "Share to Android & iOS Instantly",
            subtitle: "Send or receive files with any phone over local Wi-Fi — no cables, no apps to install, no cloud uploads.",
            symbol: "qrcode.viewfinder",
            accent: Color(red: 0.0, green: 0.478, blue: 1.0),
            highlights: [
                ("qrcode", "Scan QR & Download on Any Phone", "Share videos, photos, PDFs, or whole collections to Android or iPhone in one click."),
                ("arrow.down.circle", "Two-Way Receive from Phone", "Send photos and videos from your phone straight into your ChronoStream Inbox folder."),
                ("lock.shield", "4-Digit PIN & AirDrop Support", "Every Wi-Fi session is protected with a rotating 4-digit PIN and auto-expires automatically.")
            ]
        ),
        OnboardingSlide(
            id: 4,
            badge: "READY TO START",
            title: "100% Private. Completely Yours.",
            subtitle: "ChronoStream only reads folders you explicitly authorize. Connect a folder now or explore the workspace.",
            symbol: "lock.shield.fill",
            accent: Color(red: 0.0, green: 0.478, blue: 1.0),
            highlights: [
                ("folder.badge.plus", "You Control Folder Access", "Authorize any local folder with one click — nothing is ever uploaded or synced to the cloud."),
                ("chart.bar.xaxis", "Local Activity & Storage Insights", "See your real watch time and library breakdown recorded 100% locally on your Mac."),
                ("play.circle.fill", "Ready Whenever You Are", "Click Get Started below to jump straight into ChronoStream.")
            ]
        )
    ]

    private var currentSlide: OnboardingSlide {
        slides[currentIndex]
    }

    private var isLastSlide: Bool {
        currentIndex == slides.count - 1
    }

    private var surfaceBg: Color {
        colorScheme == .light ? Color(red: 0.975, green: 0.982, blue: 0.988) : Color(nsColor: .windowBackgroundColor)
    }

    private var cardBg: Color {
        colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top bar with step counter & Skip
            HStack {
                HStack(spacing: 8) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text("ChronoStream")
                        .font(.callout.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Step \(currentIndex + 1) of \(slides.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !isLastSlide {
                    Button("Skip") {
                        onContinue()
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Animated slide stage
            ZStack {
                slideContent(currentSlide)
                    .id(currentSlide.id)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: slideDirection >= 0 ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: slideDirection >= 0 ? .leading : .trailing).combined(with: .opacity)
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            // Bottom navigation & Start CTA
            HStack(spacing: 14) {
                if currentIndex > 0 {
                    Button {
                        goTo(currentIndex - 1)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Color.clear.frame(width: 78, height: 1)
                }

                Spacer()

                // Progress dots
                HStack(spacing: 7) {
                    ForEach(slides.indices, id: \.self) { idx in
                        Capsule()
                            .fill(idx == currentIndex ? currentSlide.accent : Color.primary.opacity(0.16))
                            .frame(width: idx == currentIndex ? 22 : 7, height: 7)
                            .onTapGesture {
                                goTo(idx)
                            }
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: currentIndex)

                Spacer()

                if isLastSlide {
                    HStack(spacing: 10) {
                        Button {
                            onAddFolder()
                        } label: {
                            Label("Add Folder…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            onContinue()
                        } label: {
                            Label("Get Started", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.0, green: 0.478, blue: 1.0))
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                } else {
                    Button {
                        goTo(currentIndex + 1)
                    } label: {
                        HStack(spacing: 5) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(currentSlide.accent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(cardBg)
        }
        .background(surfaceBg)
        .frame(width: 680, height: 530)
    }

    private func goTo(_ next: Int) {
        let clamped = max(0, min(slides.count - 1, next))
        guard clamped != currentIndex else { return }
        slideDirection = clamped > currentIndex ? 1 : -1
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            currentIndex = clamped
        }
    }

    private func slideContent(_ slide: OnboardingSlide) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(slide.accent.opacity(0.12))
                        .frame(width: 66, height: 66)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(slide.accent.opacity(0.24), lineWidth: 1)
                        )
                    Image(systemName: slide.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(slide.accent)
                }

                Text(slide.badge)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(slide.accent)

                Text(slide.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text(slide.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(slide.highlights.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(slide.accent)
                            .frame(width: 34, height: 34)
                            .background(slide.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 580, alignment: .leading)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .light ? 0.04 : 0), radius: 12, y: 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}
