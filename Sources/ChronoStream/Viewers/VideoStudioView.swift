import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum VideoToolTab: String, CaseIterable, Identifiable {
    case trim = "Trim / Cut"
    case transform = "Crop & Speed"
    case merge = "Merge Two"
    case replaceAudio = "Change Audio"
    case extractAudio = "Extract Audio"
    var id: String { rawValue }
}

public struct VideoStudioView: View {
    @Bindable var store: LibraryStore
    @State private var activeTool: VideoToolTab = .trim

    // Trim state
    @State private var trimInput: URL?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 30
    @State private var trimLossless: Bool = true

    // Crop & Transform state
    @State private var transformInput: URL?
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0
    @State private var rotationDegrees: Int = 0
    @State private var videoSpeed: Double = 1.0
    @State private var muteAudio: Bool = false

    // Merge state
    @State private var mergeFirst: URL?
    @State private var mergeSecond: URL?

    // Replace Audio state
    @State private var replaceVideo: URL?
    @State private var replaceAudio: URL?

    // Extract Audio state
    @State private var extractVideo: URL?
    @State private var extractFormat: String = "m4a"

    @State private var isProcessing: Bool = false
    @State private var resultMessage: String?
    @State private var lastExportURL: URL?

    public init(store: LibraryStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Studio Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Studio")
                        .font(.headline)
                    Text("Fast, offline video trimming, cropping, merging, and audio tools powered by FFmpeg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Tool", selection: $activeTool) {
                    ForEach(VideoToolTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    switch activeTool {
                    case .trim: trimForm
                    case .transform: transformForm
                    case .merge: mergeForm
                    case .replaceAudio: replaceAudioForm
                    case .extractAudio: extractAudioForm
                    }

                    if let msg = resultMessage {
                        HStack {
                            Image(systemName: lastExportURL != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(lastExportURL != nil ? .green : .orange)
                            Text(msg).font(.callout)
                            Spacer()
                            if let url = lastExportURL {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 620)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    // MARK: - Tool Forms

    private var trimForm: some View {
        Form {
            Section("Source Video") {
                filePickerRow(label: "Video File", url: trimInput, type: .movie) { trimInput = $0 }
            }
            Section("Cut Range (Seconds)") {
                HStack {
                    Text("Start")
                    TextField("0", value: $trimStart, format: .number).frame(width: 90)
                    Text("End")
                    TextField("30", value: $trimEnd, format: .number).frame(width: 90)
                    Spacer()
                    Text("Duration: \(MediaFormatting.timeString(max(0, trimEnd - trimStart)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("Lossless fast cut (instant stream copy, zero quality loss)", isOn: $trimLossless)
            }
            actionSection(title: "Export Trimmed MP4…", disabled: trimInput == nil || trimEnd <= trimStart) {
                guard let input = trimInput, let out = savePanel(defaultName: input.deletingPathExtension().lastPathComponent + "_cut.mp4", type: .mpeg4Movie) else { return }
                runJob { await FFmpegBridge.shared.trimVideo(input: input, startSeconds: trimStart, endSeconds: trimEnd, lossless: trimLossless, output: out) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
    }

    private var transformForm: some View {
        Form {
            Section("Source Video") {
                filePickerRow(label: "Video File", url: transformInput, type: .movie) { transformInput = $0 }
            }
            Section("Crop Margins") {
                HStack { Text("Left \(Int(cropLeft * 100))%").frame(width: 78, alignment: .leading); Slider(value: $cropLeft, in: 0...0.4) }
                HStack { Text("Right \(Int(cropRight * 100))%").frame(width: 78, alignment: .leading); Slider(value: $cropRight, in: 0...0.4) }
                HStack { Text("Top \(Int(cropTop * 100))%").frame(width: 78, alignment: .leading); Slider(value: $cropTop, in: 0...0.4) }
                HStack { Text("Bottom \(Int(cropBottom * 100))%").frame(width: 78, alignment: .leading); Slider(value: $cropBottom, in: 0...0.4) }
            }
            Section("Rotation, Speed & Audio") {
                Picker("Rotate", selection: $rotationDegrees) {
                    Text("None").tag(0)
                    Text("90° CW").tag(90)
                    Text("180°").tag(180)
                    Text("270° CW").tag(270)
                }
                .pickerStyle(.segmented)

                Picker("Playback Speed", selection: $videoSpeed) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)

                Toggle("Mute / Remove audio track", isOn: $muteAudio)
            }
            actionSection(title: "Export Edited Video…", disabled: transformInput == nil) {
                guard let input = transformInput, let out = savePanel(defaultName: input.deletingPathExtension().lastPathComponent + "_edited.mp4", type: .mpeg4Movie) else { return }
                runJob {
                    await FFmpegBridge.shared.cropAndTransformVideo(
                        input: input,
                        cropLeft: cropLeft, cropRight: cropRight, cropTop: cropTop, cropBottom: cropBottom,
                        rotationDegrees: rotationDegrees, muteAudio: muteAudio, speed: videoSpeed, output: out
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
    }

    private var mergeForm: some View {
        Form {
            Section("Select Two Videos to Merge") {
                filePickerRow(label: "First Video", url: mergeFirst, type: .movie) { mergeFirst = $0 }
                filePickerRow(label: "Second Video", url: mergeSecond, type: .movie) { mergeSecond = $0 }
            }
            actionSection(title: "Merge & Export MP4…", disabled: mergeFirst == nil || mergeSecond == nil) {
                guard let a = mergeFirst, let b = mergeSecond, let out = savePanel(defaultName: "Merged_Video.mp4", type: .mpeg4Movie) else { return }
                runJob { await FFmpegBridge.shared.mergeTwoVideos(first: a, second: b, output: out) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
    }

    private var replaceAudioForm: some View {
        Form {
            Section("Replace Video Audio Track") {
                filePickerRow(label: "Video File", url: replaceVideo, type: .movie) { replaceVideo = $0 }
                filePickerRow(label: "New Audio Track", url: replaceAudio, type: .audio) { replaceAudio = $0 }
            }
            actionSection(title: "Replace Audio & Export MP4…", disabled: replaceVideo == nil || replaceAudio == nil) {
                guard let v = replaceVideo, let a = replaceAudio, let out = savePanel(defaultName: v.deletingPathExtension().lastPathComponent + "_newaudio.mp4", type: .mpeg4Movie) else { return }
                runJob { await FFmpegBridge.shared.replaceAudio(video: v, audio: a, output: out) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
    }

    private var extractAudioForm: some View {
        Form {
            Section("Extract Audio From Video") {
                filePickerRow(label: "Video File", url: extractVideo, type: .movie) { extractVideo = $0 }
                Picker("Output Format", selection: $extractFormat) {
                    Text("AAC (.m4a)").tag("m4a")
                    Text("MP3 (.mp3)").tag("mp3")
                }
                .pickerStyle(.segmented)
            }
            actionSection(title: "Extract Audio…", disabled: extractVideo == nil) {
                guard let v = extractVideo else { return }
                let type: UTType = extractFormat == "mp3" ? .mp3 : .mpeg4Audio
                guard let out = savePanel(defaultName: v.deletingPathExtension().lastPathComponent + ".\(extractFormat)", type: type) else { return }
                runJob { await FFmpegBridge.shared.extractAudio(video: v, format: extractFormat, output: out) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
    }

    // MARK: - Helpers

    private func filePickerRow(label: String, url: URL?, type: UTType, onPick: @escaping (URL) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(url?.lastPathComponent ?? "None selected")
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
            Button("Choose…") {
                let p = NSOpenPanel()
                p.allowedContentTypes = [type]
                if p.runModal() == .OK, let picked = p.url { onPick(picked) }
            }
        }
    }

    private func actionSection(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Section {
            HStack {
                if isProcessing {
                    ProgressView().controlSize(.small)
                    Text("Processing with FFmpeg…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || disabled)
            }
        }
    }

    private func savePanel(defaultName: String, type: UTType) -> URL? {
        let s = NSSavePanel()
        s.allowedContentTypes = [type]
        s.nameFieldStringValue = defaultName
        return s.runModal() == .OK ? s.url : nil
    }

    private func runJob(_ work: @escaping @Sendable () async -> Result<URL, Error>) {
        isProcessing = true
        resultMessage = nil
        lastExportURL = nil
        Task {
            let res = await work()
            isProcessing = false
            switch res {
            case .success(let url):
                lastExportURL = url
                resultMessage = "Exported \(url.lastPathComponent)"
            case .failure(let err):
                resultMessage = err.localizedDescription
            }
        }
    }
}
