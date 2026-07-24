import Foundation

enum MLXMetadata {
    struct ArchitectureInfo {
        let family: String
        let display: String?
    }

    static func architectureInfo(at url: URL) -> ArchitectureInfo? {
        let directory = canonicalDirectory(for: url)
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var family: String?
        if let modelType = json["model_type"] as? String, !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            family = modelType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if family == nil {
            if let architectures = json["architectures"] as? [Any] {
                family = architectures
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            } else if let architecture = json["architectures"] as? String, !architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                family = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let modelFamily = json["model_family"] as? String, !modelFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                family = modelFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let resolvedFamily = family, !resolvedFamily.isEmpty else { return nil }

        var variant: String?
        if let architectures = json["architectures"] as? [Any] {
            variant = architectures
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        } else if let architecture = json["architectures"] as? String, !architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variant = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let name = json["model_name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variant = name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let name = json["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variant = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let display = variant.flatMap(Self.prettyArchitectureName(from:)) ?? Self.prettyArchitectureName(from: resolvedFamily)
        return ArchitectureInfo(family: resolvedFamily, display: display)
    }

    static func moeInfo(at url: URL) -> MoEInfo? {
        let directory = canonicalDirectory(for: url)
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let expertCountKeys = ["num_experts", "num_local_experts", "n_experts", "n_routed_experts"]
        let expertsPerTokenKeys = ["num_experts_per_tok", "num_experts_per_token", "experts_per_tok", "experts_per_token"]
        let moeLayerKeys = ["num_moe_layers", "n_moe_layers", "moe_layer_count", "moe_layers", "n_router_layers"]
        let totalLayerKeys = ["num_hidden_layers", "n_layers", "num_layers", "n_decoder_layers"]
        let hiddenSizeKeys = ["hidden_size", "n_embd", "d_model"]
        let feedForwardKeys = ["intermediate_size", "ffn_hidden_size", "ffn_dim", "mlp_hidden_dim", "ffn_size"]
        let vocabKeys = ["vocab_size", "n_vocab"]

        let expertCandidates = expertCountKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
        let expertsPerToken = expertsPerTokenKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()
        var combinedExperts = expertCandidates
        if let perToken = expertsPerToken { combinedExperts.append(perToken) }
        let resolvedExpertCount = combinedExperts.max() ?? 0
        let isMoE = combinedExperts.contains { $0 > 1 }

        let defaultUsed: Int? = {
            guard let perToken = expertsPerToken, perToken > 0 else { return nil }
            if resolvedExpertCount > 0 {
                return max(1, min(resolvedExpertCount, perToken))
            }
            return max(1, perToken)
        }()

        let moeLayerCount = moeLayerKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()
        let totalLayerCount = totalLayerKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()
        let hiddenSize = hiddenSizeKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()
        let feedForwardSize = feedForwardKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()
        let vocabSize = vocabKeys
            .compactMap { key -> Int? in
                guard let raw = json[key] else { return nil }
                return largestInt(in: raw)
            }
            .max()

        return MoEInfo(
            isMoE: isMoE,
            expertCount: resolvedExpertCount,
            defaultUsed: defaultUsed,
            moeLayerCount: moeLayerCount,
            totalLayerCount: totalLayerCount,
            hiddenSize: hiddenSize,
            feedForwardSize: feedForwardSize,
            vocabSize: vocabSize
        )
    }

    private static func canonicalDirectory(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : url.deletingLastPathComponent()
        }
        return url
    }

    private static func prettyArchitectureName(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var working = trimmed
        let suffixes = [
            "ForCausalLM",
            "ForConditionalGeneration",
            "ForQuestionAnswering",
            "Model",
            "LMHead",
            "LM"
        ]
        for suffix in suffixes {
            if working.hasSuffix(suffix) {
                working.removeLast(suffix.count)
            }
        }
        working = working.replacingOccurrences(of: "_", with: " ")
        working = working.replacingOccurrences(of: "-", with: " ")
        working = working.replacingOccurrences(of: #"(?<=[a-z0-9])(?=[A-Z])"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"(?<=[A-Z])(?=[A-Z][a-z])"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let tokens = working.split(separator: " ")
        guard !tokens.isEmpty else { return trimmed }
        let capitalized = tokens.map { token -> String in
            let upper = token.uppercased()
            if upper == token { return String(token) }
            var tokenString = String(token)
            if tokenString.count == 1 { return tokenString.uppercased() }
            let first = tokenString.removeFirst()
            return String(first).uppercased() + tokenString
        }.joined(separator: " ")
        return capitalized.isEmpty ? trimmed : capitalized
    }

    private static func largestInt(in value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed) { return Int(double) }
            if let range = trimmed.range(of: "-?\\d+", options: .regularExpression) {
                return Int(trimmed[range])
            }
            return nil
        }
        if let array = value as? [Any] {
            return array.compactMap { largestInt(in: $0) }.max()
        }
        if let dict = value as? [String: Any] {
            return dict.values.compactMap { largestInt(in: $0) }.max()
        }
        return nil
    }
}
