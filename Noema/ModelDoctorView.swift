import SwiftUI

struct ModelDoctorSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openDoctor: () -> Void

    private struct Summary: Equatable {
        var ready = 0
        var warning = 0
        var blocked = 0
        var total = 0
    }
    @State private var summary = Summary()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: summarySymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(summaryTint)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Model Doctor"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openDoctor) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Model Doctor"))
            }

            HStack(spacing: 8) {
                DoctorCapsuleMetric(title: LocalizedStringKey("Ready"), value: "\(summary.ready)")
                DoctorCapsuleMetric(title: LocalizedStringKey("Warnings"), value: "\(summary.warning)")
                DoctorCapsuleMetric(title: LocalizedStringKey("Blocked"), value: "\(summary.blocked)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openDoctor)
        .task(id: modelSignature) { await refresh() }
    }

    private var modelSignature: String {
        modelManager.downloadedModels.map(\.url.path).joined(separator: "|")
    }

    // Compute the report counts without blocking the scroll runloop: the GGUF
    // metadata reads (the expensive part) are warmed off the main thread, then
    // the small report tally is built from the now-cached values.
    @MainActor
    private func refresh() async {
        let models = modelManager.downloadedModels
        let ggufURLs = models.filter { $0.format == .gguf }.map(\.url)
        await Task.detached(priority: .utility) {
            for url in ggufURLs { GGUFMetadata.prewarm(at: url) }
        }.value
        guard !Task.isCancelled else { return }
        let loadedPath = modelManager.loadedModel?.url.path
        var result = Summary()
        result.total = models.count
        for model in models {
            let report = ModelDoctorReport(
                model: model,
                settings: modelManager.displaySettings(for: model),
                isLoaded: loadedPath == model.url.path
            )
            switch report.overallStatus {
            case .ready: result.ready += 1
            case .warning: result.warning += 1
            case .blocked: result.blocked += 1
            }
        }
        summary = result
    }

    private var summaryLine: String {
        guard summary.total > 0 else {
            return String(localized: "Install a local model to run checks")
        }
        let format = String(localized: "%d models checked")
        return String.localizedStringWithFormat(format, summary.total)
    }

    private var summarySymbol: String {
        if summary.blocked > 0 { return "stethoscope.circle.fill" }
        if summary.warning > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private var summaryTint: Color {
        if summary.blocked > 0 { return .red }
        if summary.warning > 0 { return .orange }
        return .green
    }
}

struct ModelDoctorView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var selectedModelPath: String = ""
    @State private var reportExportURL: URL?
    @State private var reportExportError: String?
    @State private var checkedAt = Date()

    private var availableModels: [LocalModel] {
        modelManager.downloadedModels.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedModel: LocalModel? {
        if let model = availableModels.first(where: { $0.url.path == selectedModelPath }) {
            return model
        }
        return availableModels.first
    }

    private var selectedReport: ModelDoctorReport? {
        guard let model = selectedModel else { return nil }
        return ModelDoctorReport(
            model: model,
            settings: modelManager.displaySettings(for: model),
            isLoaded: modelManager.loadedModel?.url.path == model.url.path
        )
    }

    var body: some View {
        Form {
            if availableModels.isEmpty {
                Section(LocalizedStringKey("Model Doctor")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LocalizedStringKey("No local models installed"), systemImage: "tray")
                            .font(.headline)
                        Text(LocalizedStringKey("Install a local model to run file, memory, template, sidecar, tool, vision, and speculative decoding checks."))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section(LocalizedStringKey("Model")) {
                    Picker(LocalizedStringKey("Check Model"), selection: selectedPathBinding) {
                        ForEach(availableModels, id: \.id) { model in
                            Text(verbatim: modelLabel(model)).tag(model.url.path)
                        }
                    }
                }

                if let report = selectedReport {
                    overviewSection(report)
                    recommendationsSection(report)
                    checksSection(report)
                    runtimeSection(report)
                    exportSection(report)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Model Doctor"))
        .onAppear(perform: ensureSelection)
        .onReceive(modelManager.$downloadedModels) { _ in ensureSelection() }
    }

    private var selectedPathBinding: Binding<String> {
        Binding(
            get: {
                if selectedModelPath.isEmpty {
                    return availableModels.first?.url.path ?? ""
                }
                return selectedModelPath
            },
            set: { selectedModelPath = $0 }
        )
    }

    private func ensureSelection() {
        guard !availableModels.isEmpty else {
            selectedModelPath = ""
            return
        }
        if selectedModelPath.isEmpty || !availableModels.contains(where: { $0.url.path == selectedModelPath }) {
            selectedModelPath = modelManager.loadedModel?.url.path ?? availableModels.first?.url.path ?? ""
        }
    }

    private func modelLabel(_ model: LocalModel) -> String {
        let suffix = model.quant.isEmpty ? model.format.displayName : "\(model.quant) · \(model.format.displayName)"
        return "\(model.name) (\(suffix))"
    }

    @ViewBuilder
    private func overviewSection(_ report: ModelDoctorReport) -> some View {
        Section(LocalizedStringKey("Compatibility Report")) {
            DoctorStatusRow(
                title: LocalizedStringKey("Overall"),
                value: report.overallStatus.localizedTitle,
                systemImage: report.overallStatus.systemImage,
                tint: report.overallStatus.tint
            )
            DoctorValueRow(title: LocalizedStringKey("Runtime Path"), value: report.runtimePath)
            DoctorValueRow(title: LocalizedStringKey("Load State"), value: report.isLoaded ? String(localized: "Loaded now") : String(localized: "Not loaded"))
            DoctorValueRow(title: LocalizedStringKey("Last Checked"), value: checkedAt.formatted(date: .omitted, time: .standard))

            Button {
                checkedAt = Date()
            } label: {
                Label(LocalizedStringKey("Run Model Doctor"), systemImage: "stethoscope")
            }
        }
    }

    @ViewBuilder
    private func recommendationsSection(_ report: ModelDoctorReport) -> some View {
        Section(LocalizedStringKey("Recommendations")) {
            if report.recommendations.isEmpty {
                Label(LocalizedStringKey("No immediate action needed"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(report.recommendations, id: \.self) { recommendation in
                    Text(verbatim: recommendation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func checksSection(_ report: ModelDoctorReport) -> some View {
        Section(LocalizedStringKey("Checks")) {
            ForEach(report.checks) { check in
                DoctorStatusRow(
                    title: LocalizedStringKey(check.titleKey),
                    value: check.value,
                    systemImage: check.status.systemImage,
                    tint: check.status.tint
                )
            }
        }
    }

    @ViewBuilder
    private func runtimeSection(_ report: ModelDoctorReport) -> some View {
        Section(LocalizedStringKey("Runtime Budget")) {
            DoctorValueRow(title: LocalizedStringKey("Context Length"), value: report.contextValue)
            DoctorValueRow(title: LocalizedStringKey("Estimated Working Set"), value: report.workingSetValue)
            DoctorValueRow(title: LocalizedStringKey("Memory Budget"), value: report.budgetValue)
            DoctorValueRow(title: LocalizedStringKey("Safe Context"), value: report.safeContextValue)
            DoctorValueRow(title: LocalizedStringKey("KV Cache"), value: report.kvCacheValue)
        }
    }

    @ViewBuilder
    private func exportSection(_ report: ModelDoctorReport) -> some View {
        Section(LocalizedStringKey("Doctor Export")) {
            Button {
                generateExport(report)
            } label: {
                Label(LocalizedStringKey("Generate Doctor JSON"), systemImage: "doc.badge.gearshape")
            }

            if let reportExportURL {
                ShareLink(item: reportExportURL) {
                    Label(LocalizedStringKey("Share Doctor JSON"), systemImage: "square.and.arrow.up")
                }
                DoctorValueRow(title: LocalizedStringKey("Export File"), value: reportExportURL.lastPathComponent)
            }

            if let reportExportError {
                DoctorValueRow(title: LocalizedStringKey("Export Error"), value: reportExportError)
            }
        }
    }

    private func generateExport(_ report: ModelDoctorReport) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report.exportDictionary, options: [.prettyPrinted, .sortedKeys])
            let fileName = "noema-model-doctor-\(Self.sanitizedFileToken(report.modelName)).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: [.atomic])
            reportExportURL = url
            reportExportError = nil
        } catch {
            reportExportURL = nil
            reportExportError = error.localizedDescription
        }
    }

    private static func sanitizedFileToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "model" : collapsed
    }
}

private struct DoctorCapsuleMetric: View {
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

private struct DoctorValueRow: View {
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

private struct DoctorStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct ModelDoctorCheck: Identifiable {
    let id = UUID()
    let titleKey: String
    let value: String
    let status: ModelDoctorStatus
}

private enum ModelDoctorStatus: String {
    case ready
    case warning
    case blocked

    var localizedTitle: String {
        switch self {
        case .ready: return String(localized: "Ready")
        case .warning: return String(localized: "Needs attention")
        case .blocked: return String(localized: "Blocked")
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}

private struct ModelDoctorReport {
    let modelName: String
    let modelID: String
    let format: ModelFormat
    let quant: String
    let fileName: String
    let fileExists: Bool
    let isLoaded: Bool
    let runtimePath: String
    let contextValue: String
    let workingSetValue: String
    let budgetValue: String
    let safeContextValue: String
    let kvCacheValue: String
    let checks: [ModelDoctorCheck]
    let recommendations: [String]
    let overallStatus: ModelDoctorStatus

    init(model: LocalModel, settings: ModelSettings, isLoaded: Bool) {
        let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
        let layerCount = model.totalLayers > 0 ? model.totalLayers : GGUFMetadata.layerCount(at: model.url)
        let moeInfo = model.moeInfo ?? (model.format == .gguf ? GGUFMetadata.moeInfo(at: model.url) : nil)
        let kvEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
        let contextLength = max(512, Int(settings.contextLength.rounded()))
        let (workingSet, budget) = ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            contextLength: contextLength,
            layerCount: layerCount,
            moeInfo: moeInfo,
            kvCacheEstimate: kvEstimate
        )
        let safeContext = ModelRAMAdvisor.maxContextUnderBudget(
            format: model.format,
            sizeBytes: sizeBytes,
            layerCount: layerCount,
            moeInfo: moeInfo,
            upperBound: GGUFMetadata.contextLength(at: model.url),
            kvCacheEstimate: kvEstimate
        )

        modelName = model.name
        modelID = model.modelID
        format = model.format
        quant = model.quant
        fileName = model.url.lastPathComponent
        fileExists = FileManager.default.fileExists(atPath: model.url.path)
        self.isLoaded = isLoaded
        runtimePath = Self.runtimePath(for: model.format)
        contextValue = String.localizedStringWithFormat(String(localized: "%d tokens"), contextLength)
        workingSetValue = ByteCountFormatter.string(fromByteCount: workingSet, countStyle: .memory)
        budgetValue = budget.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? String(localized: "Unknown")
        safeContextValue = safeContext.map { String.localizedStringWithFormat(String(localized: "%d tokens"), $0) } ?? String(localized: "Unknown")
        kvCacheValue = "\(kvEstimate.kCacheQuant.rawValue) / \(kvEstimate.vCacheQuant.rawValue)"

        let reportContext = ReportContext(
            model: model,
            settings: settings,
            fileExists: fileExists,
            workingSet: workingSet,
            budget: budget,
            safeContext: safeContext,
            contextLength: contextLength,
            layerCount: layerCount
        )
        checks = Self.makeChecks(context: reportContext)
        recommendations = Self.makeRecommendations(context: reportContext, checks: checks)

        if checks.contains(where: { $0.status == .blocked }) {
            overallStatus = .blocked
        } else if checks.contains(where: { $0.status == .warning }) {
            overallStatus = .warning
        } else {
            overallStatus = .ready
        }
    }

    var exportDictionary: [String: Any] {
        [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "overallStatus": overallStatus.rawValue,
            "model": [
                "id": modelID,
                "name": modelName,
                "format": format.rawValue,
                "quant": quant,
                "file": fileName,
                "fileExists": fileExists,
                "isLoaded": isLoaded
            ],
            "runtime": [
                "path": runtimePath,
                "context": contextValue,
                "workingSet": workingSetValue,
                "memoryBudget": budgetValue,
                "safeContext": safeContextValue,
                "kvCache": kvCacheValue
            ],
            "checks": checks.map { check in
                [
                    "title": check.titleKey,
                    "status": check.status.rawValue,
                    "value": check.value
                ]
            },
            "recommendations": recommendations
        ]
    }

    private struct ReportContext {
        let model: LocalModel
        let settings: ModelSettings
        let fileExists: Bool
        let workingSet: Int64
        let budget: Int64?
        let safeContext: Int?
        let contextLength: Int
        let layerCount: Int?
    }

    private static func makeChecks(context: ReportContext) -> [ModelDoctorCheck] {
        let model = context.model
        let settings = context.settings
        let gguf = model.format == .gguf
        let projectorPath = gguf ? ProjectorLocator.projectorPath(alongside: model.url) : nil
        let hasMergedProjector = gguf && GGUFMetadata.hasMultimodalProjector(at: model.url)
        let hasProjector = projectorPath != nil || hasMergedProjector
        let wantsVision = model.isMultimodal || hasProjector
        let mtpPath = gguf ? MtpLocator.mtpPath(alongside: model.url) : nil
        let hasEmbeddedMTP = gguf && GGUFMetadata.hasMTP(at: model.url)
        let hasMTP = mtpPath != nil || hasEmbeddedMTP
        let template = gguf ? GGUFMetadata.chatTemplate(at: model.url) : nil
        let trainingContext = gguf ? GGUFMetadata.contextLength(at: model.url) : nil
        let tokenizerPath = ModelSettings.resolvedTokenizerPath(for: model)

        var checks: [ModelDoctorCheck] = []

        checks.append(ModelDoctorCheck(
            titleKey: "Model File",
            value: context.fileExists ? String(localized: "Present") : String(localized: "Missing"),
            status: context.fileExists ? .ready : .blocked
        ))

        checks.append(ModelDoctorCheck(
            titleKey: "Runtime Path",
            value: runtimePath(for: model.format),
            status: .ready
        ))

        let ramStatus: ModelDoctorStatus = {
            guard let budget = context.budget else { return .warning }
            if context.workingSet <= budget { return .ready }
            if context.workingSet <= Int64(Double(budget) * 1.15) { return .warning }
            return .blocked
        }()
        checks.append(ModelDoctorCheck(
            titleKey: "RAM Fit",
            value: context.budget == nil
                ? String(localized: "Budget unknown")
                : "\(ByteCountFormatter.string(fromByteCount: context.workingSet, countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: context.budget ?? 0, countStyle: .memory))",
            status: ramStatus
        ))

        let contextStatus: ModelDoctorStatus = {
            if let safe = context.safeContext, context.contextLength > safe { return .warning }
            if let trainingContext, context.contextLength > trainingContext { return .warning }
            return .ready
        }()
        checks.append(ModelDoctorCheck(
            titleKey: "Context Setting",
            value: String.localizedStringWithFormat(String(localized: "%d tokens"), context.contextLength),
            status: contextStatus
        ))

        let templateStatus: ModelDoctorStatus = {
            if !gguf { return .ready }
            return template?.isEmpty == false ? .ready : .warning
        }()
        checks.append(ModelDoctorCheck(
            titleKey: "Chat Template",
            value: gguf ? (template?.isEmpty == false ? String(localized: "Present") : String(localized: "Missing")) : String(localized: "Managed by backend"),
            status: templateStatus
        ))

        checks.append(ModelDoctorCheck(
            titleKey: "Tokenizer",
            value: gguf ? String(localized: "Embedded in GGUF") : (tokenizerPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Managed by backend")),
            status: .ready
        ))

        let visionStatus: ModelDoctorStatus = {
            guard wantsVision else { return .ready }
            if gguf && !hasProjector { return .blocked }
            return .ready
        }()
        checks.append(ModelDoctorCheck(
            titleKey: "Vision Readiness",
            value: visionValue(wantsVision: wantsVision, hasProjector: hasProjector, projectorPath: projectorPath, merged: hasMergedProjector),
            status: visionStatus
        ))

        let toolCapable = model.isToolCapable || ToolCapabilityDetector.isToolCapableLocal(url: model.url, format: model.format)
        checks.append(ModelDoctorCheck(
            titleKey: "Tool Calling",
            value: toolCapable ? String(localized: "Detected") : String(localized: "Not detected"),
            status: toolCapable ? .ready : .warning
        ))

        let mtpStatus: ModelDoctorStatus = {
            guard settings.speculativeDecoding.selection == .mtp else { return hasMTP ? .ready : .warning }
            return hasMTP ? .ready : .blocked
        }()
        checks.append(ModelDoctorCheck(
            titleKey: "MTP Readiness",
            value: mtpValue(enabled: settings.speculativeDecoding.selection == .mtp, hasMTP: hasMTP, mtpPath: mtpPath, embedded: hasEmbeddedMTP),
            status: mtpStatus
        ))

        return checks
    }

    private static func makeRecommendations(context: ReportContext, checks: [ModelDoctorCheck]) -> [String] {
        var values: [String] = []
        let model = context.model
        let failingTitles = Set(checks.filter { $0.status == .blocked }.map(\.titleKey))
        let warningTitles = Set(checks.filter { $0.status == .warning }.map(\.titleKey))

        if failingTitles.contains("Model File") {
            values.append(String(localized: "Repair or reinstall this model because the expected local file is missing."))
        }
        if failingTitles.contains("RAM Fit") || warningTitles.contains("RAM Fit") {
            if let safe = context.safeContext {
                let format = String(localized: "Lower context to %@ tokens or use a smaller quant before loading.")
                values.append(String.localizedStringWithFormat(format, "\(safe)"))
            } else {
                values.append(String(localized: "Try a smaller quant or disable memory-heavy options before loading."))
            }
        }
        if warningTitles.contains("Context Setting"), let safe = context.safeContext, context.contextLength > safe {
            let format = String(localized: "The current context is above the safe estimate; try %@ tokens.")
            values.append(String.localizedStringWithFormat(format, "\(safe)"))
        }
        if failingTitles.contains("Vision Readiness") {
            values.append(String(localized: "Pair a compatible projector GGUF before using image input with this model."))
        }
        if warningTitles.contains("Chat Template") {
            values.append(String(localized: "Add or select a chat template if replies look poorly formatted."))
        }
        if warningTitles.contains("Tool Calling") {
            values.append(String(localized: "Use the Tool Store test before relying on automatic tool calls."))
        }
        if failingTitles.contains("MTP Readiness") {
            values.append(String(localized: "Disable MTP or install the matching draft head before loading."))
        } else if warningTitles.contains("MTP Readiness"), model.format == .gguf {
            values.append(String(localized: "Install a matching MTP draft head if you want speculative decoding."))
        }
        if values.isEmpty, model.format == .gguf, context.settings.flashAttention == false {
            values.append(String(localized: "Consider the Balanced or Max Speed preset if you want faster GGUF generation."))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func runtimePath(for format: ModelFormat) -> String {
        switch format {
        case .gguf: return String(localized: "llama.cpp loopback")
        case .mlx: return String(localized: "MLX runtime")
        case .et: return String(localized: "ExecuTorch runtime")
        case .ane: return String(localized: "Core ML runtime")
        case .afm: return String(localized: "Apple Foundation Models")
        case .coreai: return String(localized: "Core AI runtime")
        }
    }

    private static func visionValue(wantsVision: Bool, hasProjector: Bool, projectorPath: String?, merged: Bool) -> String {
        guard wantsVision else { return String(localized: "Text only") }
        if let projectorPath {
            return URL(fileURLWithPath: projectorPath).lastPathComponent
        }
        if merged {
            return String(localized: "Merged in GGUF")
        }
        return hasProjector ? String(localized: "Ready") : String(localized: "Projector missing")
    }

    private static func mtpValue(enabled: Bool, hasMTP: Bool, mtpPath: String?, embedded: Bool) -> String {
        if let mtpPath {
            return URL(fileURLWithPath: mtpPath).lastPathComponent
        }
        if embedded {
            return String(localized: "Embedded MTP head")
        }
        if enabled {
            return String(localized: "Enabled but missing")
        }
        return hasMTP ? String(localized: "Available") : String(localized: "Not installed")
    }
}
