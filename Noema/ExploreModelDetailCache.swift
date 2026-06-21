import Foundation

struct ExploreModelDetailSnapshot: Codable, Equatable {
    let details: ModelDetails
    let cachedAt: Date
}

enum ExploreModelDetailCache {
    static let detailsFilename = "details.json"

    static func directory(for repoID: String, root: URL? = nil, create: Bool = true) -> URL {
        var base = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("ModelCards", isDirectory: true)
        for component in safePathComponents(for: repoID) {
            base.appendPathComponent(component, isDirectory: true)
        }
        if create {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func save(_ details: ModelDetails, root: URL? = nil, date: Date = Date()) {
        let snapshot = ExploreModelDetailSnapshot(details: details, cachedAt: date)
        let url = directory(for: details.id, root: root).appendingPathComponent(detailsFilename)
        guard let data = try? JSONEncoder.noemaCacheEncoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func snapshot(repoID: String, root: URL? = nil) -> ExploreModelDetailSnapshot? {
        let url = directory(for: repoID, root: root, create: false).appendingPathComponent(detailsFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.noemaCacheDecoder.decode(ExploreModelDetailSnapshot.self, from: data)
    }

    static func cachedAt(repoID: String, root: URL? = nil) -> Date? {
        snapshot(repoID: repoID, root: root)?.cachedAt
    }

    static func records(root: URL? = nil) -> [ModelRecord] {
        let base = modelCardsRoot(root: root, create: false)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [ExploreModelDetailSnapshot] = []
        for case let url as URL in enumerator where url.lastPathComponent == detailsFilename {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder.noemaCacheDecoder.decode(ExploreModelDetailSnapshot.self, from: data) else {
                continue
            }
            snapshots.append(snapshot)
        }

        var seen = Set<String>()
        return snapshots
            .sorted { $0.cachedAt > $1.cachedAt }
            .compactMap { snapshot in
                guard seen.insert(snapshot.details.id).inserted else { return nil }
                return record(from: snapshot.details)
            }
    }

    static func record(from details: ModelDetails) -> ModelRecord {
        let owner = details.id.split(separator: "/").first.map(String.init) ?? ""
        let displayName = details.id.split(separator: "/").last.map(String.init) ?? details.id
        return ModelRecord(
            id: details.id,
            displayName: displayName
                .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            publisher: owner,
            summary: details.summary,
            parameterCountLabel: details.parameterCountLabel,
            hasInstallableQuant: !details.quants.isEmpty,
            formats: Set(details.quants.map(\.format)),
            installed: false,
            tags: nil,
            pipeline_tag: nil,
            minRAMBytes: details.minRAMBytes,
            recommendedETBackend: nil,
            supportsVision: details.isVision
        )
    }

    private static func modelCardsRoot(root: URL?, create: Bool) -> URL {
        var base = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        base.appendPathComponent("ModelCards", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    private static func safePathComponents(for repoID: String) -> [String] {
        let components = repoID
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { component in
                component != "." && component != ".." && !component.isEmpty
            }
        return components.isEmpty ? ["unknown"] : components
    }
}

private extension JSONEncoder {
    static var noemaCacheEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var noemaCacheDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
