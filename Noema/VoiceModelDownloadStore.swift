import SwiftUI
#if canImport(TTSKit) && !arch(x86_64)
import TTSKit
#endif

/// Downloads the neural voice weights via TTSKit's Hub downloader (real
/// progress callbacks), then loads the pipeline once so CoreML compiles and
/// the tokenizer is cached for offline use. Shared so Settings and the
/// voice-mode first-run card drive the same download.
@MainActor
final class VoiceModelDownloadStore: ObservableObject {
    static let shared = VoiceModelDownloadStore()

    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isPreparing = false
    @Published var error: String?

    func downloadIfNeeded() async {
        guard !isDownloading else { return }
        if VoiceModelCatalog.installState() == .ready { return }
        isDownloading = true
        isPreparing = false
        error = nil
        progress = 0
        defer {
            isDownloading = false
            isPreparing = false
        }
#if canImport(TTSKit) && !arch(x86_64)
        var downloadCompleted = false
        do {
            try FileManager.default.createDirectory(
                at: VoiceModelCatalog.baseDirectory,
                withIntermediateDirectories: true
            )
            var folder = try await TTSKit.download(
                variant: .qwen3TTS_0_6b,
                downloadBase: VoiceModelCatalog.baseDirectory,
                endpoint: HFEndpoint.baseURL?.absoluteString ?? Qwen3TTSConstants.defaultEndpoint,
                progressCallback: { [weak self] hubProgress in
                    let fraction = hubProgress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.progress = max(self.progress, min(0.9, fraction * 0.9))
                    }
                }
            )
            folder = folder.standardizedFileURL
            Task { await logger.log("[VoiceModelDownload] resolved folder=\(folder.path)") }

            // Record before the compile pass: if the load below crashes or is
            // jetsammed, the finished download is still adoptable on relaunch.
            VoiceModelCatalog.recordInstalled(folder: folder)
            downloadCompleted = true

            // First load compiles the CoreML components and pulls the tokenizer
            // into the Hub cache so later sessions work fully offline.
            isPreparing = true
            progress = max(progress, 0.9)
            _ = try await TTSKit(model: .qwen3TTS_0_6b, modelFolder: folder, download: false)
            Task { await logger.log("[VoiceModelDownload] prepared and recorded install") }
            progress = 1
        } catch {
            Task { await logger.log("[VoiceModelDownload] Failed: \(error.localizedDescription)") }
            self.error = String(localized: "Voice model download failed. Try again.")
            // A prepare-phase failure leaves the finished download in place;
            // only a failed download itself invalidates the record.
            if !downloadCompleted {
                VoiceModelCatalog.clearInstalledRecord()
            }
        }
#else
        error = String(localized: "The neural voice engine is unavailable.")
#endif
    }

    func repairAndDownload() async {
        VoiceModelCatalog.deleteInstalledModel()
        progress = 0
        error = nil
        await downloadIfNeeded()
    }

    func delete() {
        guard !isDownloading else { return }
        VoiceModelCatalog.deleteInstalledModel()
        progress = 0
        error = nil
    }
}

/// Settings drill-in for the neural voice model, modeled on WhisperModelsView.
struct VoiceModelCatalogView: View {
    @StateObject private var store = VoiceModelDownloadStore.shared
    @State private var installState = VoiceModelCatalog.installState()
#if os(macOS)
    @Environment(\.dismiss) private var dismiss
#endif

    var body: some View {
#if os(macOS)
        macBody
            .onAppear { installState = VoiceModelCatalog.installState() }
            .onChangeCompat(of: store.isDownloading) { _, downloading in
                if !downloading { installState = VoiceModelCatalog.installState() }
            }
#else
        iosBody
#endif
    }

#if os(macOS)
    private var macBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("Voice Model"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppTheme.text)
                        Text(verbatim: VoiceModelCatalog.displayName)
                            .industrialStat()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    IndustrialIconButton(systemImage: "xmark", help: LocalizedStringKey("Close")) {
                        dismiss()
                    }
                    .accessibilityLabel(LocalizedStringKey("Close"))
                }

                VStack(alignment: .leading, spacing: 10) {
                    IndustrialSectionHeader(
                        "Voice Model",
                        detail: sizeLabel,
                        dotColor: macStateDotColor
                    ) {
                        macStateBadge
                    }

                    Text(LocalizedStringKey("Natural neural voice for Voice Mode, running fully on-device on the Neural Engine."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.isDownloading {
                        VStack(alignment: .leading, spacing: 5) {
                            IndustrialProgressBar(value: store.progress)
                            Text(LocalizedStringKey(store.isPreparing ? "Preparing voice model…" : "Downloading voice model…"))
                                .industrialStat()
                        }
                        .padding(.top, 2)
                    }

                    if let error = store.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        if installState != .missing {
                            Button(role: .destructive) {
                                store.delete()
                                installState = VoiceModelCatalog.installState()
                            } label: {
                                Label(LocalizedStringKey("Delete Voice Model"), systemImage: "trash")
                            }
                            .buttonStyle(.industrial(.destructive))
                            .disabled(store.isDownloading)
                        }

                        Spacer()

                        if installState != .missing {
                            Button {
                                Task {
                                    await store.repairAndDownload()
                                    installState = VoiceModelCatalog.installState()
                                }
                            } label: {
                                Label(LocalizedStringKey("Repair and Download Again"), systemImage: "wrench.and.screwdriver")
                            }
                            .buttonStyle(.industrial(.quiet))
                            .disabled(store.isDownloading)
                        }

                        if installState != .ready {
                            Button {
                                Task {
                                    await store.downloadIfNeeded()
                                    installState = VoiceModelCatalog.installState()
                                }
                            } label: {
                                Label(LocalizedStringKey("Download"), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.industrial(.prominent))
                            .disabled(store.isDownloading)
                        }
                    }
                    .padding(.top, 4)

                    Text(LocalizedStringKey("The neural voice supports English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and Italian. Other languages use the system voice."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppTheme.windowBackground.ignoresSafeArea())
    }

    private var macStateDotColor: Color {
        switch installState {
        case .ready: return .green
        case .incomplete: return .orange
        case .missing: return Color.secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var macStateBadge: some View {
        switch installState {
        case .ready:
            IndustrialBadge("Ready", tint: .green)
        case .incomplete:
            IndustrialBadge("Incomplete Download", tint: .orange)
        case .missing:
            IndustrialBadge("Not Downloaded", tint: .secondary)
        }
    }
#endif

    private var iosBody: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(VoiceModelCatalog.displayName)
                            .font(.headline)
                        Spacer()
                        stateBadge
                    }
                    Text(LocalizedStringKey("Natural neural voice for Voice Mode, running fully on-device on the Neural Engine."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if store.isDownloading {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: store.progress)
                            Text(LocalizedStringKey(store.isPreparing ? "Preparing voice model…" : "Downloading voice model…"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = store.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)

                if installState != .ready {
                    Button {
                        Task {
                            await store.downloadIfNeeded()
                            installState = VoiceModelCatalog.installState()
                        }
                    } label: {
                        Label(LocalizedStringKey("Download"), systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isDownloading)
                }

                if installState != .missing {
                    Button {
                        Task {
                            await store.repairAndDownload()
                            installState = VoiceModelCatalog.installState()
                        }
                    } label: {
                        Label(LocalizedStringKey("Repair and Download Again"), systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(store.isDownloading)

                    Button(role: .destructive) {
                        store.delete()
                        installState = VoiceModelCatalog.installState()
                    } label: {
                        Label(LocalizedStringKey("Delete Voice Model"), systemImage: "trash")
                    }
                    .disabled(store.isDownloading)
                }
            } footer: {
                Text(LocalizedStringKey("The neural voice supports English, Chinese, Japanese, Korean, German, French, Russian, Portuguese, Spanish, and Italian. Other languages use the system voice."))
            }
        }
        .navigationTitle(Text("Voice Model"))
        .onAppear { installState = VoiceModelCatalog.installState() }
        .onChangeCompat(of: store.isDownloading) { _, downloading in
            if !downloading { installState = VoiceModelCatalog.installState() }
        }
    }

    private var stateBadge: some View {
        let state: (key: String, color: Color) = {
            switch installState {
            case .ready: return ("Ready", .green)
            case .incomplete: return ("Incomplete Download", .orange)
            case .missing: return ("Not Downloaded", .secondary)
            }
        }()
        return Text(LocalizedStringKey(state.key))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.color)
    }

    private var sizeLabel: String {
        let bytes = installState == .ready
            ? VoiceModelCatalog.installedSizeBytes
            : VoiceModelCatalog.approximateSizeBytes
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return installState == .ready
            ? formatted
            : String.localizedStringWithFormat(String(localized: "About %@ download"), formatted)
    }
}
