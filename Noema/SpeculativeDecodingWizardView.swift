import SwiftUI

struct SpeculativeDecodingWizardSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openWizard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Speculative Wizard"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openWizard) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Speculative Wizard"))
            }

            HStack(spacing: 8) {
                SpecWizardPill(title: LocalizedStringKey("MTP"), value: "\(mtpCount)")
                SpecWizardPill(title: LocalizedStringKey("Helpers"), value: "\(helperReadyCount)")
                SpecWizardPill(title: LocalizedStringKey("GGUF"), value: "\(ggufModels.count)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openWizard)
    }

    private var ggufModels: [LocalModel] {
        modelManager.downloadedModels.filter { $0.format == .gguf }
    }

    private var mtpCount: Int {
        ggufModels.filter { SpeculativeRecommendationEngine.hasMTP($0) }.count
    }

    private var helperReadyCount: Int {
        ggufModels.filter { model in
            !SpeculativeRecommendationEngine.helperCandidates(for: model, among: ggufModels).isEmpty
        }.count
    }

    private var summaryLine: String {
        guard !ggufModels.isEmpty else {
            return String(localized: "Install GGUF models to compare draft options")
        }
        let format = String(localized: "%d GGUF models can be evaluated")
        return String.localizedStringWithFormat(format, ggufModels.count)
    }
}

struct SpeculativeDecodingWizardView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var selectedModelPath: String = ""
    @State private var selectedHelperID: String = ""
    @State private var applyMessage: String?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showAdvanced = false

    private var ggufModels: [LocalModel] {
        modelManager.downloadedModels
            .filter { $0.format == .gguf }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedModel: LocalModel? {
        if let model = ggufModels.first(where: { $0.url.path == selectedModelPath }) {
            return model
        }
        return ggufModels.first
    }

    private var selectedPlan: SpeculativeRecommendationPlan? {
        guard let model = selectedModel else { return nil }
        return SpeculativeRecommendationEngine.plan(for: model, among: ggufModels)
    }

    var body: some View {
        Form {
            if ggufModels.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LocalizedStringKey("No GGUF models installed"), systemImage: "tray")
                            .font(.headline)
                        Text(LocalizedStringKey("Speculative decoding speeds up GGUF models. Install one to choose between a built-in draft head, a smaller helper model, or leaving it off."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    Picker(LocalizedStringKey("Model"), selection: selectedPathBinding) {
                        ForEach(ggufModels, id: \.id) { model in
                            Text(verbatim: modelLabel(model)).tag(model.url.path)
                        }
                    }
                } footer: {
                    Text(LocalizedStringKey("Speculative decoding drafts several tokens with a fast source, then verifies them with this model — keeping quality while improving speed."))
                }

                if let plan = selectedPlan {
                    recommendationSection(plan)
                    draftSourceSection(plan)
                    advancedSection(plan)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Speculative Wizard"))
        .onAppear(perform: ensureSelection)
        .onReceive(modelManager.$downloadedModels) { _ in ensureSelection() }
        .onChange(of: selectedModelPath) { _, _ in
            applyMessage = nil
            exportError = nil
            exportURL = nil
            selectedHelperID = ""
        }
    }

    private var selectedPathBinding: Binding<String> {
        Binding(
            get: {
                if selectedModelPath.isEmpty {
                    return ggufModels.first?.url.path ?? ""
                }
                return selectedModelPath
            },
            set: { selectedModelPath = $0 }
        )
    }

    private func ensureSelection() {
        guard !ggufModels.isEmpty else {
            selectedModelPath = ""
            return
        }
        if selectedModelPath.isEmpty || !ggufModels.contains(where: { $0.url.path == selectedModelPath }) {
            selectedModelPath = modelManager.loadedModel?.format == .gguf
                ? (modelManager.loadedModel?.url.path ?? ggufModels.first?.url.path ?? "")
                : (ggufModels.first?.url.path ?? "")
        }
    }

    private func modelLabel(_ model: LocalModel) -> String {
        let suffix = model.quant.isEmpty ? model.format.displayName : "\(model.quant) · \(model.format.displayName)"
        return "\(model.name) (\(suffix))"
    }

    @ViewBuilder
    private func recommendationSection(_ plan: SpeculativeRecommendationPlan) -> some View {
        Section(LocalizedStringKey("Recommendation")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: plan.recommendationIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(plan.tint)
                        .frame(width: 40, height: 40)
                        .background(plan.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey("Recommended"))
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(verbatim: plan.recommendationTitle)
                            .font(.headline)
                    }

                    Spacer(minLength: 0)
                }

                Text(verbatim: plan.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    apply(plan)
                } label: {
                    Label(LocalizedStringKey("Apply Recommendation"), systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.canApply)

                if let applyMessage {
                    Label(applyMessage, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func draftSourceSection(_ plan: SpeculativeRecommendationPlan) -> some View {
        Section(LocalizedStringKey("Draft Source")) {
            SpecCandidateRow(
                title: LocalizedStringKey("Built-in draft (MTP)"),
                value: plan.mtpAvailable ? plan.mtpSource : String(localized: "Not available for this model"),
                icon: plan.mtpAvailable ? "bolt.fill" : "bolt.slash",
                tint: plan.mtpAvailable ? .green : .secondary
            )

            if plan.helperCandidates.isEmpty {
                SpecCandidateRow(
                    title: LocalizedStringKey("Helper model"),
                    value: String(localized: "Install a smaller same-family GGUF to enable"),
                    icon: "rectangle.stack.badge.minus",
                    tint: .secondary
                )
            } else {
                Picker(LocalizedStringKey("Helper model"), selection: selectedHelperBinding(for: plan)) {
                    ForEach(plan.helperCandidates) { candidate in
                        Text(verbatim: candidate.model.name).tag(candidate.id)
                    }
                }

                if let candidate = selectedHelperCandidate(in: plan) {
                    Text(verbatim: candidate.compatibilitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    applySelectedHelper(plan)
                } label: {
                    Label(LocalizedStringKey("Use This Helper"), systemImage: "link")
                }
            }
        }
    }

    @ViewBuilder
    private func advancedSection(_ plan: SpeculativeRecommendationPlan) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                let settings = modelManager.displaySettings(for: plan.target)
                SpecValueRow(title: LocalizedStringKey("Speculative Mode"), value: settings.speculativeDecoding.selection.title)
                SpecValueRow(title: LocalizedStringKey("Helper Model"), value: currentHelperName(settings))
                SpecValueRow(title: LocalizedStringKey("MTP Draft Tokens"), value: "\(settings.speculativeDecoding.resolvedMTPDraftNMax)")
                SpecValueRow(title: LocalizedStringKey("MTP Min Draft Tokens"), value: "\(settings.speculativeDecoding.resolvedMTPDraftNMin)")
                SpecValueRow(title: LocalizedStringKey("MTP Draft P-Min"), value: String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin))

                Button {
                    generateExport(plan)
                } label: {
                    Label(LocalizedStringKey("Generate Speculative JSON"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share Speculative JSON"), systemImage: "square.and.arrow.up")
                    }
                }

                if let exportError {
                    Text(verbatim: exportError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } label: {
                Label(LocalizedStringKey("Advanced"), systemImage: "slider.horizontal.3")
            }
        }
    }

    private func currentHelperName(_ settings: ModelSettings) -> String {
        guard let helperID = settings.speculativeDecoding.helperModelID, !helperID.isEmpty else {
            return String(localized: "None")
        }
        return ggufModels.first(where: { $0.modelID == helperID })?.name ?? helperID
    }

    private func apply(_ plan: SpeculativeRecommendationPlan) {
        guard plan.canApply else { return }
        var settings = modelManager.displaySettings(for: plan.target)
        switch plan.recommendation {
        case .mtp:
            settings.speculativeDecoding.selection = .mtp
            settings.speculativeDecoding.helperModelID = nil
            settings.speculativeDecoding.mtpDraftNMax = 2
            settings.speculativeDecoding.mtpDraftNMin = 0
            settings.speculativeDecoding.mtpDraftPMin = 0.1
        case .helper:
            settings.speculativeDecoding.selection = .helperDraftModel
            settings.speculativeDecoding.helperModelID = plan.recommendedHelperID
            settings.speculativeDecoding.mode = .tokens
            settings.speculativeDecoding.value = 64
        case .off:
            settings.speculativeDecoding.selection = .off
            settings.speculativeDecoding.helperModelID = nil
        }
        modelManager.updateSettings(settings, for: plan.target)
        applyMessage = String(localized: "Speculative settings updated")
    }

    private func applySelectedHelper(_ plan: SpeculativeRecommendationPlan) {
        guard let candidate = selectedHelperCandidate(in: plan) else { return }
        var settings = modelManager.displaySettings(for: plan.target)
        settings.speculativeDecoding.selection = .helperDraftModel
        settings.speculativeDecoding.helperModelID = candidate.model.modelID
        settings.speculativeDecoding.mode = .tokens
        settings.speculativeDecoding.value = 64
        modelManager.updateSettings(settings, for: plan.target)
        applyMessage = String(localized: "Helper model pairing updated")
    }

    private func selectedHelperBinding(for plan: SpeculativeRecommendationPlan) -> Binding<String> {
        Binding(
            get: {
                if selectedHelperID.isEmpty || !plan.helperCandidates.contains(where: { $0.id == selectedHelperID }) {
                    return plan.helperCandidates.first(where: { $0.model.modelID == plan.recommendedHelperID })?.id
                        ?? plan.helperCandidates.first?.id
                        ?? ""
                }
                return selectedHelperID
            },
            set: { selectedHelperID = $0 }
        )
    }

    private func selectedHelperCandidate(in plan: SpeculativeRecommendationPlan) -> SpeculativeHelperCandidate? {
        if selectedHelperID.isEmpty {
            return plan.helperCandidates.first(where: { $0.model.modelID == plan.recommendedHelperID }) ?? plan.helperCandidates.first
        }
        return plan.helperCandidates.first(where: { $0.id == selectedHelperID }) ?? plan.helperCandidates.first
    }

    private func generateExport(_ plan: SpeculativeRecommendationPlan) {
        do {
            let data = try JSONSerialization.data(withJSONObject: plan.exportDictionary, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-speculative-wizard.json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }
}

private struct SpecWizardPill: View {
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

private struct SpecRecommendationRow: View {
    let plan: SpeculativeRecommendationPlan

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: plan.recommendationTitle)
                    .font(.headline)
                Text(verbatim: plan.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Label(LocalizedStringKey("Best Option"), systemImage: plan.recommendationIcon)
                .foregroundStyle(plan.tint)
        }
    }
}

private struct SpecCandidateRow: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Label(title, systemImage: icon)
                .foregroundStyle(tint)
        }
    }
}

private struct SpecValueRow: View {
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

private struct SpeculativeHelperCandidate: Identifiable {
    let id: String
    let model: LocalModel
    let summary: String
    let family: String
    let sizeSummary: String
    let sizeRatioSummary: String
    let compatibilitySummary: String
    let exportDictionary: [String: Any]
}

private enum SpeculativeRecommendationKind: String {
    case mtp
    case helper
    case off
}

private struct SpeculativeRecommendationPlan {
    let target: LocalModel
    let recommendation: SpeculativeRecommendationKind
    let recommendationTitle: String
    let recommendationIcon: String
    let tint: Color
    let reason: String
    let mtpAvailable: Bool
    let mtpSource: String
    let helperCandidates: [SpeculativeHelperCandidate]
    let recommendedHelperID: String?

    var canApply: Bool {
        switch recommendation {
        case .mtp:
            return mtpAvailable
        case .helper:
            return recommendedHelperID?.isEmpty == false
        case .off:
            return true
        }
    }

    var exportDictionary: [String: Any] {
        [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "target": [
                "name": target.name,
                "modelID": target.modelID,
                "format": target.format.rawValue,
                "quant": target.quant,
                "path": target.url.path
            ],
            "recommendation": [
                "kind": recommendation.rawValue,
                "title": recommendationTitle,
                "reason": reason,
                "recommendedHelperID": recommendedHelperID ?? ""
            ],
            "mtp": [
                "available": mtpAvailable,
                "source": mtpSource
            ],
            "helperCandidates": helperCandidates.map(\.exportDictionary)
        ]
    }
}

private enum SpeculativeRecommendationEngine {
    static func plan(for target: LocalModel, among models: [LocalModel]) -> SpeculativeRecommendationPlan {
        let helpers = helperCandidates(for: target, among: models)
        let mtp = hasMTP(target)
        let mtpSource = mtpSource(for: target)

        if mtp {
            return SpeculativeRecommendationPlan(
                target: target,
                recommendation: .mtp,
                recommendationTitle: String(localized: "Use MTP"),
                recommendationIcon: "bolt.fill",
                tint: .green,
                reason: String(localized: "This model has an embedded or sidecar draft head, so MTP is the lowest-friction option."),
                mtpAvailable: true,
                mtpSource: mtpSource,
                helperCandidates: helpers,
                recommendedHelperID: nil
            )
        }

        if let helper = helpers.first {
            return SpeculativeRecommendationPlan(
                target: target,
                recommendation: .helper,
                recommendationTitle: String(localized: "Use Helper Model"),
                recommendationIcon: "rectangle.stack.fill",
                tint: .green,
                reason: String(localized: "No MTP head was found, but a smaller same-family GGUF can draft tokens."),
                mtpAvailable: false,
                mtpSource: mtpSource,
                helperCandidates: helpers,
                recommendedHelperID: helper.model.modelID
            )
        }

        return SpeculativeRecommendationPlan(
            target: target,
            recommendation: .off,
            recommendationTitle: String(localized: "Leave Off"),
            recommendationIcon: "bolt.slash",
            tint: .secondary,
            reason: String(localized: "No compatible MTP head or smaller helper model is installed for this target."),
            mtpAvailable: false,
            mtpSource: mtpSource,
            helperCandidates: helpers,
            recommendedHelperID: nil
        )
    }

    static func hasMTP(_ model: LocalModel) -> Bool {
        MtpLocator.hasMtpFile(alongside: model.url) || GGUFMetadata.hasMTP(at: model.url)
    }

    static func helperCandidates(for target: LocalModel, among models: [LocalModel]) -> [SpeculativeHelperCandidate] {
        models
            .filter { candidate in
                candidate.id != target.id &&
                candidate.format == .gguf &&
                sizeBytes(candidate) < sizeBytes(target) &&
                sameFamily(target, candidate)
            }
            .sorted {
                let lhsSize = sizeBytes($0)
                let rhsSize = sizeBytes($1)
                if lhsSize != rhsSize { return lhsSize > rhsSize }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { candidate in
                let targetBytes = sizeBytes(target)
                let candidateBytes = sizeBytes(candidate)
                let ratio = targetBytes > 0 ? Double(candidateBytes) / Double(targetBytes) : 0
                let family = displayFamily(target)
                return SpeculativeHelperCandidate(
                    id: candidate.url.path,
                    model: candidate,
                    summary: "\(candidate.name) · \(candidate.quant.isEmpty ? candidate.format.displayName : candidate.quant) · \(byteString(sizeBytes(candidate)))",
                    family: family,
                    sizeSummary: byteString(candidateBytes),
                    sizeRatioSummary: ratioString(ratio),
                    compatibilitySummary: compatibilitySummary(ratio: ratio),
                    exportDictionary: [
                        "name": candidate.name,
                        "modelID": candidate.modelID,
                        "quant": candidate.quant,
                        "path": candidate.url.path,
                        "sizeBytes": candidateBytes,
                        "targetSizeBytes": targetBytes,
                        "sizeRatio": ratio,
                        "family": family
                    ]
                )
            }
    }

    private static func mtpSource(for model: LocalModel) -> String {
        if let path = MtpLocator.mtpPath(alongside: model.url) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if GGUFMetadata.hasMTP(at: model.url) {
            return String(localized: "Embedded MTP head")
        }
        return String(localized: "Not installed")
    }

    private static func sameFamily(_ lhs: LocalModel, _ rhs: LocalModel) -> Bool {
        let lhsFamily = normalizedFamily(lhs)
        let rhsFamily = normalizedFamily(rhs)
        if lhsFamily.isEmpty || rhsFamily.isEmpty { return false }
        return lhsFamily == rhsFamily ||
            lhsFamily.contains(rhsFamily) ||
            rhsFamily.contains(lhsFamily)
    }

    private static func normalizedFamily(_ model: LocalModel) -> String {
        let source = model.architectureFamily.isEmpty ? model.architecture : model.architectureFamily
        let fallback = model.modelID.split(separator: "/").last.map(String.init) ?? model.name
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : source
        return raw
            .lowercased()
            .replacingOccurrences(of: "\\b(qwen2|qwen3|llama3|llama|gemma2|gemma3|gemma|mistral|phi3|phi4|phi)\\b", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\b(instruct|chat|it|base|q[0-9a-z_]+|f16|fp16|bf16|gguf|mlx|slm)\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayFamily(_ model: LocalModel) -> String {
        let source = model.architectureFamily.isEmpty ? model.architecture : model.architectureFamily
        let fallback = model.modelID.split(separator: "/").last.map(String.init) ?? model.name
        let family = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : source
        return family.isEmpty ? String(localized: "Same family") : family
    }

    private static func ratioString(_ ratio: Double) -> String {
        guard ratio > 0 else { return String(localized: "Unknown") }
        return String.localizedStringWithFormat(String(localized: "%.0f%% of target"), ratio * 100)
    }

    private static func compatibilitySummary(ratio: Double) -> String {
        switch ratio {
        case 0.45..<0.85:
            return String(localized: "Same family, close enough to draft useful tokens")
        case 0.20..<0.45:
            return String(localized: "Same family, lightweight helper")
        case 0.85..<1.0:
            return String(localized: "Same family, but may save less memory")
        default:
            return String(localized: "Same-family helper candidate")
        }
    }

    private static func sizeBytes(_ model: LocalModel) -> Int64 {
        Int64(model.sizeGB * 1_073_741_824.0)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
