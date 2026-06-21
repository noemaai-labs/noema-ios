import Foundation

struct ModelDownloadPlan: Equatable {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case weights
            case weightShard
            case config
            case importanceMatrix
            case mtp
            case tokenizer
            case template
            case processor
            case projector
            case params
        }

        let kind: Kind
        let relativePath: String
        let sizeBytes: Int64?
        let isRequired: Bool
        let isResolvedDuringInstall: Bool

        var id: String {
            "\(kind)-\(relativePath)-\(isResolvedDuringInstall)"
        }
    }

    let entries: [Entry]

    var knownFileCount: Int {
        entries.filter { !$0.isResolvedDuringInstall }.count
    }

    var installTimeCheckCount: Int {
        entries.filter(\.isResolvedDuringInstall).count
    }

    var knownTotalBytes: Int64 {
        entries.reduce(into: Int64(0)) { total, entry in
            total += max(entry.sizeBytes ?? 0, 0)
        }
    }

    var unknownSizeCount: Int {
        entries.filter { $0.sizeBytes == nil || ($0.sizeBytes ?? 0) <= 0 }.count
    }

    static func make(for quant: QuantInfo) -> ModelDownloadPlan {
        var entries = quant.allDownloadParts.enumerated().map { index, part in
            Entry(
                kind: quant.isMultipart ? .weightShard : .weights,
                relativePath: QuantInfo.relativeDownloadPath(path: part.path, fallbackURL: part.downloadURL),
                sizeBytes: part.sizeBytes > 0 ? part.sizeBytes : nil,
                isRequired: true,
                isResolvedDuringInstall: false
            )
        }

        if let configURL = quant.configURL {
            let filename = configURL.lastPathComponent.isEmpty ? "config.json" : configURL.lastPathComponent
            entries.append(
                Entry(
                    kind: sidecarKind(for: filename),
                    relativePath: filename,
                    sizeBytes: nil,
                    isRequired: quant.format == .et,
                    isResolvedDuringInstall: true
                )
            )
        }

        if let importanceMatrix = quant.importanceMatrix {
            entries.append(
                Entry(
                    kind: .importanceMatrix,
                    relativePath: QuantInfo.relativeDownloadPath(path: importanceMatrix.path, fallbackURL: importanceMatrix.downloadURL),
                    sizeBytes: importanceMatrix.sizeBytes > 0 ? importanceMatrix.sizeBytes : nil,
                    isRequired: false,
                    isResolvedDuringInstall: false
                )
            )
        }

        if let mtp = quant.mtp {
            entries.append(
                Entry(
                    kind: .mtp,
                    relativePath: QuantInfo.relativeDownloadPath(path: mtp.path, fallbackURL: mtp.downloadURL),
                    sizeBytes: mtp.sizeBytes > 0 ? mtp.sizeBytes : nil,
                    isRequired: false,
                    isResolvedDuringInstall: false
                )
            )
        }

        entries.append(contentsOf: formatSidecarChecks(for: quant.format))
        return ModelDownloadPlan(entries: entries)
    }

    private static func sidecarKind(for filename: String) -> Entry.Kind {
        let lower = filename.lowercased()
        if lower.contains("tokenizer") { return .tokenizer }
        if lower.contains("template") { return .template }
        if lower.contains("processor") || lower.contains("vision") || lower.contains("projector") { return .processor }
        if lower.contains("params") { return .params }
        return .config
    }

    private static func formatSidecarChecks(for format: ModelFormat) -> [Entry] {
        switch format {
        case .gguf:
            return [
                Entry(
                    kind: .projector,
                    relativePath: "mmproj / projector",
                    sizeBytes: nil,
                    isRequired: false,
                    isResolvedDuringInstall: true
                ),
                Entry(
                    kind: .params,
                    relativePath: "params / params.json",
                    sizeBytes: nil,
                    isRequired: false,
                    isResolvedDuringInstall: true
                )
            ]
        case .mlx:
            return [
                Entry(
                    kind: .tokenizer,
                    relativePath: "tokenizer files",
                    sizeBytes: nil,
                    isRequired: true,
                    isResolvedDuringInstall: true
                ),
                Entry(
                    kind: .template,
                    relativePath: "chat templates",
                    sizeBytes: nil,
                    isRequired: false,
                    isResolvedDuringInstall: true
                ),
                Entry(
                    kind: .processor,
                    relativePath: "vision processor files",
                    sizeBytes: nil,
                    isRequired: false,
                    isResolvedDuringInstall: true
                )
            ]
        case .et:
            return [
                Entry(
                    kind: .tokenizer,
                    relativePath: "ET tokenizer files",
                    sizeBytes: nil,
                    isRequired: true,
                    isResolvedDuringInstall: true
                )
            ]
        case .ane:
            return [
                Entry(
                    kind: .tokenizer,
                    relativePath: "ANE tokenizer files",
                    sizeBytes: nil,
                    isRequired: true,
                    isResolvedDuringInstall: true
                )
            ]
        case .afm:
            return []
        case .coreai:
            return [
                Entry(
                    kind: .tokenizer,
                    relativePath: "tokenizer files",
                    sizeBytes: nil,
                    isRequired: true,
                    isResolvedDuringInstall: true
                )
            ]
        }
    }
}
