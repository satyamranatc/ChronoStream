import SwiftUI

public struct SettingsView: View {
    @Bindable var store: LibraryStore
    @State private var thumbCacheSize: Int64 = 0
    @State private var remuxCacheSize: Int64 = 0
    @State private var ffmpegInstalled: Bool = false
    @State private var isDefaultVideoPlayer: Bool = false
    @State private var defaultStatusNote: String?
    @AppStorage("uiTextScale") private var uiTextScale: String = "comfortable"
    @AppStorage("appThemeMode") private var appThemeMode: String = "light"
    @AppStorage("uiClickSoundEnabled") private var uiClickSoundEnabled: Bool = true
    @AppStorage("uiClickSoundName") private var uiClickSoundName: String = "Tink"

    public init(store: LibraryStore) {
        self.store = store
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            libraryPrivacyTab
                .tabItem { Label("Library & Privacy", systemImage: "lock.shield") }

            formatsTab
                .tabItem { Label("Formats", systemImage: "film.stack") }
        }
        .frame(width: 520, height: 360)
        .task {
            await refreshStats()
        }
    }

    private var generalTab: some View {
        Form {
            Section("Default Video Player") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isDefaultVideoPlayer ? "ChronoStream is your default video player" : "Set ChronoStream as default for MP4, MOV & MKV")
                            .font(.callout.weight(.medium))
                        if let note = defaultStatusNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(isDefaultVideoPlayer ? "Default Active" : "Set as Default") {
                        Task {
                            let ok = await DefaultAppManager.setAsDefaultVideoPlayer()
                            isDefaultVideoPlayer = DefaultAppManager.isDefaultForMP4()
                            defaultStatusNote = ok ? "Updated macOS file associations." : "Could not update default app."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDefaultVideoPlayer)
                }
            }

            Section("Appearance & Feedback") {
                Picker("Theme", selection: $appThemeMode) {
                    Text("Pure Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)

                Picker("Interface Text Size", selection: $uiTextScale) {
                    Text("Compact (Default macOS)").tag("compact")
                    Text("Comfortable (+15%)").tag("comfortable")
                    Text("Large (+25%)").tag("large")
                }
                .pickerStyle(.segmented)

                Toggle("Subtle macOS Click Sound", isOn: $uiClickSoundEnabled)

                if uiClickSoundEnabled {
                    Picker("Click Sound", selection: $uiClickSoundName) {
                        Text("Tink (Default)").tag("Tink")
                        Text("Pop").tag("Pop")
                        Text("Morse").tag("Morse")
                        Text("Frog").tag("Frog")
                    }
                    .onChange(of: uiClickSoundName) { _, _ in
                        UISoundFeedback.shared.playClick()
                    }
                }
            }

            Section("Playback") {
                Picker("Default Video Speed", selection: $store.defaultPlaybackRate) {
                    Text("0.75×").tag(0.75)
                    Text("1× (Normal)").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }

                Slider(value: $store.slideshowInterval, in: 1.5...10.0, step: 0.5) {
                    Text("Photo Slideshow Interval")
                } minimumValueLabel: {
                    Text("1.5s")
                } maximumValueLabel: {
                    Text("10s")
                }
                Text("Current slideshow speed: \(String(format: "%.1f", store.slideshowInterval)) seconds per photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var libraryPrivacyTab: some View {
        Form {
            Section("Privacy & Folder Access") {
                Toggle("Monitor authorized folders for new files", isOn: $store.monitorFoldersEnabled)
                Text("ChronoStream only reads folders you explicitly add via macOS security-scoped bookmarks. Zero telemetry is collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bounded Disk Caches") {
                LabeledContent("Thumbnail Cache (300 MB max)", value: MediaFormatting.byteString(thumbCacheSize))
                LabeledContent("FFmpeg Remux Cache (2 GB max)", value: MediaFormatting.byteString(remuxCacheSize))
                HStack {
                    Spacer()
                    Button("Clear All Caches") {
                        Task {
                            await ThumbnailCache.shared.clearAll()
                            await FFmpegBridge.shared.clearRemuxCache()
                            await refreshStats()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var formatsTab: some View {
        Form {
            Section("Tested Format Matrix") {
                LabeledContent("Video (Native AVFoundation)", value: "MP4, M4V, MOV (H.264 / HEVC)")
                LabeledContent("Video (FFmpeg Fallback)", value: ffmpegInstalled ? "MKV, AVI, WebM, MPEG-PS (Active)" : "Install FFmpeg via Homebrew")
                LabeledContent("Audio", value: "MP3, WAV, AAC, M4A, FLAC, ALAC, OGG")
                LabeledContent("Photos (ImageIO)", value: "JPEG, PNG, HEIC, TIFF, GIF, WebP, RAW")
                LabeledContent("Documents (PDFKit)", value: "PDF with zoom & search")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func refreshStats() async {
        thumbCacheSize = await ThumbnailCache.shared.diskUsageBytes()
        remuxCacheSize = await FFmpegBridge.shared.remuxCacheBytes()
        ffmpegInstalled = await FFmpegBridge.shared.isAvailable
        isDefaultVideoPlayer = DefaultAppManager.isDefaultForMP4()
    }
}
