import SwiftUI

struct ModelStorageAdvisorSummaryContent: View {
    @ObservedObject var modelManager: AppModelManager
    let openAdvisor: () -> Void

    var body: some View {
        // Compute the snapshot once per render (it was previously rebuilt four
        // times — once per pill plus the summary line).
        let snap = snapshot
        let modelCount = snap.modelCount
        let totalSize = snap.totalSize
        let duplicateCount = snap.duplicateFamilies.count
        let line = modelCount > 0
            ? String.localizedStringWithFormat(String(localized: "%@ across %d models"), totalSize, modelCount)
            : String(localized: "No local models installed")

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("Storage Advisor"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: line)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openAdvisor) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open Storage Advisor"))
            }

            HStack(spacing: 8) {
                StorageCapsuleMetric(title: LocalizedStringKey("Models"), value: "\(modelCount)")
                StorageCapsuleMetric(title: LocalizedStringKey("Storage"), value: totalSize)
                StorageCapsuleMetric(title: LocalizedStringKey("Duplicates"), value: "\(duplicateCount)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openAdvisor)
    }

    private var snapshot: ModelStorageSnapshot {
        ModelStorageSnapshot(
            visibleModels: modelManager.downloadedModels,
            hiddenModels: modelManager.hiddenModels,
            loadedModelPath: modelManager.loadedModel?.url.path
        )
    }
}

struct ModelStorageAdvisorView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var snapshot: ModelStorageSnapshot {
        ModelStorageSnapshot(
            visibleModels: modelManager.downloadedModels,
            hiddenModels: modelManager.hiddenModels,
            loadedModelPath: modelManager.loadedModel?.url.path
        )
    }

    var body: some View {
#if os(macOS)
        // The iOS Form renders badly inside the Mac settings sheet (clipped
        // labels, wrong insets, stock buttons), so macOS gets a first-class
        // industrial-dialect layout instead. The sheet already supplies the
        // title + close, so no navigationTitle here.
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("Storage Advisor"))
#endif
    }

    private var formBody: some View {
        Form {
            if snapshot.modelCount == 0 {
                Section(LocalizedStringKey("Storage Advisor")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LocalizedStringKey("No local models installed"), systemImage: "tray")
                            .font(.headline)
                        Text(LocalizedStringKey("Install local models to see storage totals, duplicate families, stale models, and cleanup candidates."))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                overviewSection
                candidatesSection
                duplicatesSection
                exportSection
            }
        }
    }

    private var overviewSection: some View {
        Section(LocalizedStringKey("Storage Overview")) {
            StorageValueRow(title: LocalizedStringKey("Installed Models"), value: "\(snapshot.modelCount)")
            StorageValueRow(title: LocalizedStringKey("Visible Models"), value: "\(snapshot.visibleCount)")
            StorageValueRow(title: LocalizedStringKey("Hidden Models"), value: "\(snapshot.hiddenCount)")
            StorageValueRow(title: LocalizedStringKey("Total Model Storage"), value: snapshot.totalSize)
            StorageValueRow(title: LocalizedStringKey("Largest Model"), value: snapshot.largestModelSummary)
            StorageValueRow(title: LocalizedStringKey("Loaded Model"), value: snapshot.loadedModelName)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        Section(LocalizedStringKey("Cleanup Candidates")) {
            if snapshot.candidates.isEmpty {
                Label(LocalizedStringKey("No cleanup candidates"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(snapshot.candidates.prefix(8)) { candidate in
                    StorageCandidateRow(candidate: candidate)
                }
            }
        }
    }

    @ViewBuilder
    private var duplicatesSection: some View {
        Section(LocalizedStringKey("Duplicate Families")) {
            if snapshot.duplicateFamilies.isEmpty {
                Label(LocalizedStringKey("No duplicate families"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(snapshot.duplicateFamilies) { family in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: family.name)
                                .font(.headline)
                            Spacer()
                            Text(verbatim: family.totalSize)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: family.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section(LocalizedStringKey("Storage Export")) {
            Button {
                generateExport()
            } label: {
                Label(LocalizedStringKey("Generate Storage JSON"), systemImage: "doc.badge.gearshape")
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(LocalizedStringKey("Share Storage JSON"), systemImage: "square.and.arrow.up")
                }
                StorageValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
            }

            if let exportError {
                StorageValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
            }
        }
    }

    private func generateExport() {
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot.exportDictionary, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("noema-model-storage-advisor.json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

#if os(macOS)
    // MARK: - macOS industrial layout

    private var macBody: some View {
        MacSettingsPage {
            if snapshot.modelCount == 0 {
                MacSettingsCard(LocalizedStringKey("Storage Advisor")) {
                    MacSettingsNoteRow(LocalizedStringKey("No local models installed"), divider: false)
                    MacSettingsNoteRow(LocalizedStringKey("Install local models to see storage totals, duplicate families, stale models, and cleanup candidates."))
                }
            } else {
                MacSettingsCard(LocalizedStringKey("Storage Overview")) {
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Installed Models"), value: "\(snapshot.modelCount)", divider: false)
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Visible Models"), value: "\(snapshot.visibleCount)")
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Hidden Models"), value: "\(snapshot.hiddenCount)")
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Total Model Storage"), value: snapshot.totalSize)
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Largest Model"), value: snapshot.largestModelSummary)
                    MacSettingsKeyValueRow(title: LocalizedStringKey("Loaded Model"), value: snapshot.loadedModelName)
                }

                MacSettingsCard(LocalizedStringKey("Cleanup Candidates")) {
                    let candidates = Array(snapshot.candidates.prefix(8))
                    if candidates.isEmpty {
                        MacSettingsNoteRow(LocalizedStringKey("No cleanup candidates"), divider: false)
                    } else {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            MacStorageCandidateRow(candidate: candidate, divider: index != 0)
                        }
                    }
                }

                MacSettingsCard(LocalizedStringKey("Duplicate Families")) {
                    let families = snapshot.duplicateFamilies
                    if families.isEmpty {
                        MacSettingsNoteRow(LocalizedStringKey("No duplicate families"), divider: false)
                    } else {
                        ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                            MacStorageDuplicateRow(family: family, divider: index != 0)
                        }
                    }
                }

                MacSettingsCard(LocalizedStringKey("Storage Export")) {
                    MacSettingsActionRow(divider: false) {
                        Button {
                            generateExport()
                        } label: {
                            Label(LocalizedStringKey("Generate Storage JSON"), systemImage: "doc.badge.gearshape")
                        }
                        .buttonStyle(.industrial(.prominent))

                        if let exportURL {
                            ShareLink(item: exportURL) {
                                Label(LocalizedStringKey("Share Storage JSON"), systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.industrial(.quiet))
                        }
                    }

                    if let exportURL {
                        MacSettingsKeyValueRow(title: LocalizedStringKey("Export File"), value: exportURL.lastPathComponent)
                    }
                    if let exportError {
                        MacSettingsKeyValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                    }
                }
            }
        }
    }
#endif
}

private struct StorageCapsuleMetric: View {
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

private struct StorageValueRow: View {
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

private struct StorageCandidateRow: View {
    let candidate: ModelStorageCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: candidate.name)
                    .font(.headline)
                Spacer()
                Text(verbatim: candidate.size)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: candidate.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

#if os(macOS)
private struct MacStorageCandidateRow: View {
    let candidate: ModelStorageCandidate
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: candidate.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    IndustrialBadge(verbatim: candidate.size)
                }
                Text(verbatim: candidate.reason)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MacStorageDuplicateRow: View {
    let family: ModelStorageDuplicateFamily
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: family.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    IndustrialBadge(verbatim: family.totalSize)
                }
                Text(verbatim: family.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

struct ModelStorageCandidate: Identifiable {
    let id: String
    let name: String
    let size: String
    let reclaimableBytes: Int64
    let reason: String
    let score: Int
    let lastUsedDays: Int?
    let isLoaded: Bool
    let exportDictionary: [String: Any]
}

enum ModelStorageCleanupAdvisor {
    static func candidates(
        visibleModels: [LocalModel],
        hiddenModels: [LocalModel],
        loadedModelPath: String?,
        now: Date = Date()
    ) -> [ModelStorageCandidate] {
        let entries = visibleModels.map { (model: $0, hidden: false) } + hiddenModels.map { (model: $0, hidden: true) }
        return entries
            .compactMap { candidate(for: $0.model, hidden: $0.hidden, loadedModelPath: loadedModelPath, now: now) }
            .sorted {
                if $0.isLoaded != $1.isLoaded { return !$0.isLoaded }
                if $0.reclaimableBytes != $1.reclaimableBytes { return $0.reclaimableBytes > $1.reclaimableBytes }
                if stalenessRank($0) != stalenessRank($1) { return stalenessRank($0) > stalenessRank($1) }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func candidate(for model: LocalModel, hidden: Bool, loadedModelPath: String?, now: Date) -> ModelStorageCandidate? {
        let bytes = sizeBytes(for: model)
        let isLoaded = loadedModelPath == model.url.path
        let daysSinceUse = model.lastUsedDate.map { max(0, Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0) }
        var reasons: [String] = []
        var score = 0

        if hidden {
            reasons.append(String(localized: "Hidden model"))
            score += 35
        }
        if model.lastUsedDate == nil {
            reasons.append(String(localized: "Never loaded"))
            score += 25
        } else if let daysSinceUse, daysSinceUse >= 30 {
            let format = String(localized: "Unused for %d days")
            reasons.append(String.localizedStringWithFormat(format, daysSinceUse))
            score += min(30, daysSinceUse / 4)
        }
        if bytes >= 8 * 1_073_741_824 {
            reasons.append(String(localized: "Large model"))
            score += 20
        } else if bytes >= 4 * 1_073_741_824 {
            reasons.append(String(localized: "Medium model"))
            score += 10
        }
        if isLoaded {
            reasons.append(String(localized: "Currently loaded"))
            score -= 50
        }

        guard score > 0 else { return nil }
        return ModelStorageCandidate(
            id: model.url.path,
            name: model.name,
            size: byteString(bytes),
            reclaimableBytes: bytes,
            reason: reasons.joined(separator: " · "),
            score: score,
            lastUsedDays: daysSinceUse,
            isLoaded: isLoaded,
            exportDictionary: [
                "name": model.name,
                "modelID": model.modelID,
                "format": model.format.rawValue,
                "quant": model.quant,
                "path": model.url.path,
                "sizeBytes": bytes,
                "reclaimableBytes": bytes,
                "hidden": hidden,
                "loaded": isLoaded,
                "score": score,
                "lastUsedDays": daysSinceUse.map { $0 as Any } ?? NSNull(),
                "reasons": reasons
            ]
        )
    }

    private static func stalenessRank(_ candidate: ModelStorageCandidate) -> Int {
        candidate.lastUsedDays ?? Int.max
    }

    private static func sizeBytes(for model: LocalModel) -> Int64 {
        Int64(model.sizeGB * 1_073_741_824.0)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ModelStorageDuplicateFamily: Identifiable {
    let id: String
    let name: String
    let totalSize: String
    let totalSizeBytes: Int64
    let detail: String
    let exportDictionary: [String: Any]
}

enum ModelStorageDuplicateDetector {
    static func families(visibleModels: [LocalModel], hiddenModels: [LocalModel]) -> [ModelStorageDuplicateFamily] {
        let entries = visibleModels.map { DuplicateEntry(model: $0, hidden: false) } + hiddenModels.map { DuplicateEntry(model: $0, hidden: true) }
        let groups = Dictionary(grouping: entries, by: { identity(for: $0.model) })
        return groups.compactMap { identity, entries in
            guard entries.count > 1 else { return nil }

            let sourceIDs = Set(entries.map { sourceID(for: $0.model) })
            guard sourceIDs.count > 1 else { return nil }

            let total = entries.reduce(Int64(0)) { $0 + sizeBytes(for: $1.model) }
            let formats = Set(entries.map { $0.model.format.displayName }).sorted().joined(separator: ", ")
            let quant = displayQuant(for: entries.first?.model, fallback: identity.quant)
            let detailFormat = String(localized: "%d installs · %@ · %@")
            let detail = String.localizedStringWithFormat(detailFormat, entries.count, formats, quant)
            let sourceLabels = Array(Set(entries.map { sourceLabel(for: $0.model) })).sorted()
            let memberDictionaries = entries.map { entry in
                [
                    "name": entry.model.name,
                    "modelID": entry.model.modelID,
                    "format": entry.model.format.rawValue,
                    "quant": entry.model.quant,
                    "path": entry.model.url.path,
                    "hidden": entry.hidden,
                    "sizeBytes": sizeBytes(for: entry.model)
                ] as [String: Any]
            }

            return ModelStorageDuplicateFamily(
                id: identity.id,
                name: displayName(for: entries.first?.model, fallback: identity.stem),
                totalSize: byteString(total),
                totalSizeBytes: total,
                detail: detail,
                exportDictionary: [
                    "family": identity.id,
                    "name": displayName(for: entries.first?.model, fallback: identity.stem),
                    "installCount": entries.count,
                    "sourceCount": sourceIDs.count,
                    "sources": sourceLabels,
                    "format": identity.format.rawValue,
                    "quant": quant,
                    "totalSizeBytes": total,
                    "members": memberDictionaries
                ]
            )
        }
        .sorted {
            if $0.totalSizeBytes != $1.totalSizeBytes { return $0.totalSizeBytes > $1.totalSizeBytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private struct DuplicateEntry {
        let model: LocalModel
        let hidden: Bool
    }

    private struct DuplicateIdentity: Hashable {
        let stem: String
        let format: ModelFormat
        let quant: String

        var id: String {
            "\(stem)|\(format.rawValue.lowercased())|\(quant)"
        }
    }

    private static func identity(for model: LocalModel) -> DuplicateIdentity {
        DuplicateIdentity(
            stem: normalizedStem(for: model),
            format: model.format,
            quant: normalizedQuant(model.quant, fallback: model.format.rawValue)
        )
    }

    private static func normalizedStem(for model: LocalModel) -> String {
        let repoComponent = model.modelID
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [repoComponent, model.name, model.url.deletingPathExtension().lastPathComponent]

        for candidate in candidates.compactMap({ $0 }) {
            let stem = normalizedStem(candidate, quant: model.quant)
            if !stem.isEmpty { return stem }
        }

        return model.url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func normalizedStem(_ raw: String, quant: String) -> String {
        var value = raw.lowercased()
        value = value.replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)

        let normalizedQuant = quant
            .lowercased()
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuant.isEmpty {
            value = value.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: normalizedQuant))\\b",
                with: "",
                options: .regularExpression
            )
        }

        value = value.replacingOccurrences(
            of: "\\b(gguf|mlx|et|ane|cml|slm|coreml|xnnpack|mps)\\b",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "\\b(i?q[0-9]+(\\s+[a-z0-9]+){0,3}|f16|fp16|bf16|int4|int8|4bit|8bit)\\b",
            with: "",
            options: .regularExpression
        )
        return value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedQuant(_ raw: String, fallback: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = value.isEmpty ? fallback : value
        return resolved
            .lowercased()
            .replacingOccurrences(of: "[-_.\\s]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func sourceID(for model: LocalModel) -> String {
        let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelID.isEmpty { return modelID.lowercased() }
        return model.url.deletingLastPathComponent().path.lowercased()
    }

    private static func sourceLabel(for model: LocalModel) -> String {
        let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelID.isEmpty { return modelID }
        return model.url.deletingLastPathComponent().lastPathComponent
    }

    private static func displayName(for model: LocalModel?, fallback: String) -> String {
        guard let model else { return fallback }
        let repoComponent = model.modelID.split(separator: "/").last.map(String.init)
        let candidate = repoComponent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? repoComponent : model.name
        return (candidate ?? fallback)
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayQuant(for model: LocalModel?, fallback: String) -> String {
        guard let quant = model?.quant.trimmingCharacters(in: .whitespacesAndNewlines), !quant.isEmpty else {
            return fallback.uppercased()
        }
        return quant
    }

    private static func sizeBytes(for model: LocalModel) -> Int64 {
        Int64(model.sizeGB * 1_073_741_824.0)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ModelStorageSnapshot {
    let visibleModels: [LocalModel]
    let hiddenModels: [LocalModel]
    let loadedModelPath: String?

    private var allEntries: [(model: LocalModel, hidden: Bool)] {
        visibleModels.map { ($0, false) } + hiddenModels.map { ($0, true) }
    }

    var modelCount: Int { allEntries.count }
    var visibleCount: Int { visibleModels.count }
    var hiddenCount: Int { hiddenModels.count }

    var totalBytes: Int64 {
        allEntries.reduce(Int64(0)) { partial, entry in
            partial + Self.sizeBytes(for: entry.model)
        }
    }

    var totalSize: String {
        Self.byteString(totalBytes)
    }

    var loadedModelName: String {
        guard let loadedModelPath,
              let entry = allEntries.first(where: { $0.model.url.path == loadedModelPath }) else {
            return String(localized: "None")
        }
        return entry.model.name
    }

    var largestModelSummary: String {
        guard let entry = allEntries.max(by: { Self.sizeBytes(for: $0.model) < Self.sizeBytes(for: $1.model) }) else {
            return String(localized: "None")
        }
        return "\(entry.model.name) · \(Self.byteString(Self.sizeBytes(for: entry.model)))"
    }

    var candidates: [ModelStorageCandidate] {
        ModelStorageCleanupAdvisor.candidates(
            visibleModels: visibleModels,
            hiddenModels: hiddenModels,
            loadedModelPath: loadedModelPath
        )
    }

    var duplicateFamilies: [ModelStorageDuplicateFamily] {
        ModelStorageDuplicateDetector.families(visibleModels: visibleModels, hiddenModels: hiddenModels)
    }

    var exportDictionary: [String: Any] {
        [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "summary": [
                "modelCount": modelCount,
                "visibleCount": visibleCount,
                "hiddenCount": hiddenCount,
                "totalSizeBytes": totalBytes,
                "loadedModel": loadedModelName
            ],
            "cleanupCandidates": candidates.map(\.exportDictionary),
            "duplicateFamilies": duplicateFamilies.map(\.exportDictionary)
        ]
    }

    private static func sizeBytes(for model: LocalModel) -> Int64 {
        Int64(model.sizeGB * 1_073_741_824.0)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
