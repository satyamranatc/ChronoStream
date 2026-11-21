import AppKit
import SwiftUI

final class ChronoStreamAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?
    var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = onOpenURLs {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

@main
struct ChronoStreamApp: App {
    @NSApplicationDelegateAdaptor(ChronoStreamAppDelegate.self) private var appDelegate
    @State private var libraryStore = LibraryStore()
    @State private var videoController = VideoPlayerController()
    @State private var audioController = AudioPlayerController()
    @AppStorage("uiTextScale") private var uiTextScale: String = "comfortable"
    @AppStorage("appThemeMode") private var appThemeMode: String = "light"

    private var resolvedBaseFontSize: CGFloat {
        switch uiTextScale {
        case "compact": return 13.0
        case "large": return 16.0
        default: return 14.5
        }
    }

    private var resolvedColorScheme: ColorScheme? {
        switch appThemeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func applyNSAppearance(_ mode: String) {
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("ChronoStream") {
            MainWindowView(
                store: libraryStore,
                videoController: videoController,
                audioController: audioController
            )
            .font(.system(size: resolvedBaseFontSize))
            .preferredColorScheme(resolvedColorScheme)
            .frame(minWidth: 960, minHeight: 620)
            .onAppear {
                applyNSAppearance(appThemeMode)
                UISoundFeedback.shared.installGlobalClickMonitor()
                videoController.bind(store: libraryStore)
                audioController.bind(store: libraryStore)
                UsageStatsStore.shared.startTracking(videoController: videoController, audioController: audioController)
                appDelegate.onOpenURLs = { [weak libraryStore] urls in
                    Task { @MainActor in
                        libraryStore?.handleDroppedURLs(urls, openFirst: true)
                    }
                }
                if !appDelegate.pendingURLs.isEmpty {
                    let queued = appDelegate.pendingURLs
                    appDelegate.pendingURLs = []
                    libraryStore.handleDroppedURLs(queued, openFirst: true)
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onOpenURL { url in
                libraryStore.handleDroppedURLs([url], openFirst: true)
            }
            .onChange(of: appThemeMode) { _, newMode in
                applyNSAppearance(newMode)
            }
        }
        .windowToolbarStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Media…") {
                    libraryStore.promptOpenFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Add Media Folder…") {
                    libraryStore.promptAddFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Rescan Library") {
                    libraryStore.rescanAllFolders()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    if libraryStore.activeItem?.kind == .video {
                        videoController.togglePlayPause()
                    } else if audioController.currentItem != nil {
                        audioController.togglePlayPause()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Skip Back 10 Seconds") {
                    if libraryStore.activeItem?.kind == .video {
                        videoController.skip(by: -10)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Skip Forward 10 Seconds") {
                    if libraryStore.activeItem?.kind == .video {
                        videoController.skip(by: 10)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Divider()

                Button("Load External Subtitles…") {
                    videoController.promptLoadSubtitles()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(libraryStore.activeItem?.kind != .video)
            }

            CommandGroup(after: .toolbar) {
                Picker("Explorer Layout", selection: $libraryStore.viewMode) {
                    ForEach(ExplorerViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }
        }

        Settings {
            SettingsView(store: libraryStore)
        }
    }
}
