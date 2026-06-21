import SwiftUI
import NoemaPackages

@_silgen_name("app_memory_footprint")
private func c_unload_verifier_memory_footprint() -> UInt

struct ModelUnloadVerificationSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    let openVerifier: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: activeLocalModel == nil ? "eject" : "eject.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(activeLocalModel == nil ? Color.secondary : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Unload Verifier"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openVerifier) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Unload Verifier"))
            }

            HStack(spacing: 8) {
                ModelUnloadPill(title: LocalizedStringKey("Model"), value: activeLocalModel == nil ? String(localized: "None") : String(localized: "Loaded"))
                ModelUnloadPill(title: LocalizedStringKey("Bridge"), value: bridgeValue)
                ModelUnloadPill(title: LocalizedStringKey("Memory"), value: memoryFootprintText)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openVerifier)
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var summaryLine: String {
        if let model = activeLocalModel {
            return String.localizedStringWithFormat(String(localized: "Ready to verify unload for %@"), model.name)
        }
        if chatVM.hasActiveChatModel {
            return String(localized: "A non-local session is active")
        }
        return String(localized: "No local model is loaded")
    }

    private var bridgeValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Off") }
        return LlamaServerBridge.isLoading() ? String(localized: "Loading") : "\(port)"
    }

    private var memoryFootprintText: String {
        ByteCountFormatter.string(fromByteCount: Int64(c_unload_verifier_memory_footprint()), countStyle: .memory)
    }
}

struct ModelUnloadVerificationView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var isVerifying = false
    @State private var result: ModelUnloadVerificationResult?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Current Runtime")) {
                ModelUnloadStatusRow(
                    title: LocalizedStringKey("Loaded Model"),
                    value: currentModelValue,
                    systemImage: activeLocalModel == nil ? "shippingbox" : "shippingbox.fill",
                    tint: activeLocalModel == nil ? .secondary : .accentColor
                )
                ModelUnloadValueRow(title: LocalizedStringKey("Chat Runtime"), value: chatVM.hasActiveChatModel ? String(localized: "Active") : String(localized: "Inactive"))
                ModelUnloadValueRow(title: LocalizedStringKey("Loopback Port"), value: currentPortValue)
                ModelUnloadValueRow(title: LocalizedStringKey("Bridge State"), value: bridgeStateValue)
                ModelUnloadValueRow(title: LocalizedStringKey("Current Footprint"), value: memoryFootprintText(memoryFootprint()))
            }

            Section(LocalizedStringKey("Verification")) {
                Button {
                    Task { await runVerification() }
                } label: {
                    Label(isVerifying ? LocalizedStringKey("Verifying Unload") : LocalizedStringKey("Run Unload Verification"), systemImage: "eject")
                }
                .disabled(isVerifying || activeLocalModel == nil)

                if activeLocalModel == nil {
                    Text(LocalizedStringKey("Load a local model before running unload verification."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey("This unloads the current local model and measures memory before, immediately after, and after teardown settles."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                Section(LocalizedStringKey("Last Verification")) {
                    ModelUnloadStatusRow(
                        title: LocalizedStringKey("Result"),
                        value: result.status.title,
                        systemImage: result.status.systemImage,
                        tint: result.status.tint
                    )
                    ModelUnloadValueRow(title: LocalizedStringKey("Model Before Unload"), value: result.modelName)
                    ModelUnloadValueRow(title: LocalizedStringKey("Started"), value: result.startedAt.formatted(date: .omitted, time: .standard))
                    ModelUnloadValueRow(title: LocalizedStringKey("Completed"), value: result.completedAt.formatted(date: .omitted, time: .standard))
                    ModelUnloadValueRow(title: LocalizedStringKey("Before"), value: memoryFootprintText(result.beforeBytes))
                    ModelUnloadValueRow(title: LocalizedStringKey("After"), value: memoryFootprintText(result.afterBytes))
                    ModelUnloadValueRow(title: LocalizedStringKey("Settled"), value: memoryFootprintText(result.settledBytes))
                    ModelUnloadValueRow(title: LocalizedStringKey("Freed"), value: memoryDeltaText(result.freedBytes))
                    ModelUnloadValueRow(title: LocalizedStringKey("Port Before"), value: portText(result.portBefore))
                    ModelUnloadValueRow(title: LocalizedStringKey("Port After"), value: portText(result.portAfter))
                    ModelUnloadValueRow(title: LocalizedStringKey("Bridge After"), value: result.bridgeRunningAfter ? String(localized: "Running") : String(localized: "Stopped"))
                }

                Section(LocalizedStringKey("Unload Export")) {
                    Button {
                        generateExport(from: result)
                    } label: {
                        Label(LocalizedStringKey("Generate Unload JSON"), systemImage: "doc.badge.gearshape")
                    }

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label(LocalizedStringKey("Share Unload JSON"), systemImage: "square.and.arrow.up")
                        }
                        ModelUnloadValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                    }

                    if let exportError {
                        ModelUnloadValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Unload Verifier"))
    }

    private var activeLocalModel: LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private var currentModelValue: String {
        if let model = activeLocalModel {
            return model.name
        }
        if chatVM.hasActiveChatModel {
            return String(localized: "Non-local session")
        }
        return String(localized: "No local model loaded")
    }

    private var currentPortValue: String {
        portText(Int(LlamaServerBridge.port()))
    }

    private var bridgeStateValue: String {
        let port = Int(LlamaServerBridge.port())
        guard port > 0 else { return String(localized: "Stopped") }
        return LlamaServerBridge.isLoading() ? String(localized: "Loading") : String(localized: "Running")
    }

    @MainActor
    private func runVerification() async {
        guard let model = activeLocalModel else { return }
        isVerifying = true
        exportURL = nil
        exportError = nil

        let startedAt = Date()
        let beforeBytes = memoryFootprint()
        let portBefore = Int(LlamaServerBridge.port())

        await chatVM.unload()
        modelManager.loadedModel = nil

        let afterBytes = memoryFootprint()
        try? await Task.sleep(nanoseconds: 900_000_000)
        let settledBytes = memoryFootprint()
        let portAfter = Int(LlamaServerBridge.port())
        let bridgeRunningAfter = portAfter > 0 || LlamaServerBridge.isLoading()
        let freedBytes = beforeBytes - settledBytes

        result = ModelUnloadVerificationResult(
            modelName: model.name,
            startedAt: startedAt,
            completedAt: Date(),
            beforeBytes: beforeBytes,
            afterBytes: afterBytes,
            settledBytes: settledBytes,
            freedBytes: freedBytes,
            portBefore: portBefore,
            portAfter: portAfter,
            bridgeRunningAfter: bridgeRunningAfter,
            status: ModelUnloadVerificationStatus.make(
                beforeBytes: beforeBytes,
                settledBytes: settledBytes,
                bridgeRunningAfter: bridgeRunningAfter,
                chatHasActiveModel: chatVM.hasActiveChatModel,
                selectedModelCleared: modelManager.loadedModel == nil
            )
        )
        isVerifying = false
    }

    private func memoryFootprint() -> Int64 {
        Int64(c_unload_verifier_memory_footprint())
    }

    private func memoryFootprintText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .memory)
    }

    private func memoryDeltaText(_ bytes: Int64) -> String {
        let text = memoryFootprintText(abs(bytes))
        return bytes >= 0 ? text : String.localizedStringWithFormat(String(localized: "%@ retained"), text)
    }

    private func portText(_ port: Int) -> String {
        port > 0 ? "\(port)" : String(localized: "Off")
    }

    private func generateExport(from result: ModelUnloadVerificationResult) {
        do {
            let data = try JSONSerialization.data(withJSONObject: exportPayload(from: result), options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-unload-verification-\(Self.fileTimestamp()).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func exportPayload(from result: ModelUnloadVerificationResult) -> [String: Any] {
        [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "modelName": result.modelName,
            "startedAt": ISO8601DateFormatter().string(from: result.startedAt),
            "completedAt": ISO8601DateFormatter().string(from: result.completedAt),
            "beforeBytes": result.beforeBytes,
            "afterBytes": result.afterBytes,
            "settledBytes": result.settledBytes,
            "freedBytes": result.freedBytes,
            "portBefore": result.portBefore,
            "portAfter": result.portAfter,
            "bridgeRunningAfter": result.bridgeRunningAfter,
            "status": result.status.rawValue
        ]
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct ModelUnloadVerificationResult {
    let modelName: String
    let startedAt: Date
    let completedAt: Date
    let beforeBytes: Int64
    let afterBytes: Int64
    let settledBytes: Int64
    let freedBytes: Int64
    let portBefore: Int
    let portAfter: Int
    let bridgeRunningAfter: Bool
    let status: ModelUnloadVerificationStatus
}

private enum ModelUnloadVerificationStatus: String {
    case returned
    case partial
    case retained

    static func make(
        beforeBytes: Int64,
        settledBytes: Int64,
        bridgeRunningAfter: Bool,
        chatHasActiveModel: Bool,
        selectedModelCleared: Bool
    ) -> ModelUnloadVerificationStatus {
        let freedAtLeastThirtyTwoMiB = beforeBytes - settledBytes >= 32 * 1024 * 1024
        if !bridgeRunningAfter && !chatHasActiveModel && selectedModelCleared && (freedAtLeastThirtyTwoMiB || settledBytes <= beforeBytes) {
            return .returned
        }
        if !bridgeRunningAfter && selectedModelCleared {
            return .partial
        }
        return .retained
    }

    var title: String {
        switch self {
        case .returned:
            return String(localized: "Memory Returned")
        case .partial:
            return String(localized: "Partially Cleared")
        case .retained:
            return String(localized: "Still Retained")
        }
    }

    var systemImage: String {
        switch self {
        case .returned:
            return "checkmark.seal.fill"
        case .partial:
            return "exclamationmark.triangle.fill"
        case .retained:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .returned:
            return .green
        case .partial:
            return .orange
        case .retained:
            return .red
        }
    }
}

private struct ModelUnloadPill: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct ModelUnloadStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct ModelUnloadValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
