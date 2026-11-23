import AppKit
import SwiftUI

/// Clean, Apple-inspired animated launch splash screen that runs while the library warms up.
public struct SplashScreenView: View {
    let onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var logoVisible = false
    @State private var textVisible = false
    @State private var ringExpanded = false
    @State private var progress: CGFloat = 0.0
    @State private var statusText = "Preparing workspace…"

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    private var bgSurface: Color {
        colorScheme == .light
            ? Color(red: 0.980, green: 0.988, blue: 0.992)
            : Color(red: 0.075, green: 0.088, blue: 0.105)
    }

    public var body: some View {
        ZStack {
            bgSurface.ignoresSafeArea()

            // Subtle ambient teal radial glow
            RadialGradient(
                colors: [
                    Color.teal.opacity(colorScheme == .light ? 0.11 : 0.18),
                    Color.teal.opacity(0.0)
                ],
                center: .center,
                startRadius: 24,
                endRadius: 340
            )
            .scaleEffect(ringExpanded ? 1.12 : 0.82)
            .opacity(logoVisible ? 1 : 0)
            .ignoresSafeArea()

            VStack(spacing: 22) {
                // Animated emblem
                ZStack {
                    Circle()
                        .stroke(Color.teal.opacity(0.18), lineWidth: 1.5)
                        .frame(width: 132, height: 132)
                        .scaleEffect(ringExpanded ? 1.16 : 0.85)
                        .opacity(ringExpanded ? 0.0 : 0.9)

                    Circle()
                        .fill(colorScheme == .light ? Color.white : Color.white.opacity(0.06))
                        .frame(width: 108, height: 108)
                        .shadow(color: Color.teal.opacity(0.16), radius: 22, y: 8)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
                        )

                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 78, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Color.teal)
                    }
                }
                .scaleEffect(logoVisible ? 1.0 : 0.84)
                .opacity(logoVisible ? 1.0 : 0.0)

                // Title & subtitle
                VStack(spacing: 6) {
                    Text("ChronoStream")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(-0.4)

                    Text("Unified Media & Studio Suite")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .offset(y: textVisible ? 0 : 10)
                .opacity(textVisible ? 1.0 : 0.0)

                // Sleek hairline progress bar
                VStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 180, height: 4)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.0, green: 0.502, blue: 0.502),
                                        Color(red: 0.400, green: 0.698, blue: 0.698)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, 180 * progress), height: 4)
                    }

                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                .opacity(textVisible ? 1.0 : 0.0)
            }
        }
        .task {
            withAnimation(.spring(response: 0.52, dampingFraction: 0.82)) {
                logoVisible = true
            }
            withAnimation(.easeOut(duration: 1.25)) {
                ringExpanded = true
            }
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.easeOut(duration: 0.4)) {
                textVisible = true
            }
            withAnimation(.easeInOut(duration: 0.55)) {
                progress = 0.58
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            statusText = "Ready"
            withAnimation(.easeOut(duration: 0.45)) {
                progress = 1.0
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            onFinished()
        }
    }
}
