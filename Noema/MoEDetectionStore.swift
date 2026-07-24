import Foundation

actor MoEDetectionStore {
    static let shared = MoEDetectionStore()

    private let directoryURL: URL
    private let fileURL: URL
    private var cache: [String: MoEInfo]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = docs.appendingPathComponent("ModelMetadata", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("moe-info.json", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: MoEInfo].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    private func ensureDirectory() {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func persist() {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func key(modelID: String, quantLabel: String) -> String {
        "\(modelID)|\(quantLabel)"
    }

    func all() -> [String: MoEInfo] { cache }

    func info(forModelID modelID: String, quantLabel: String) -> MoEInfo? {
        cache[Self.key(modelID: modelID, quantLabel: quantLabel)]
    }

    func update(info: MoEInfo, modelID: String, quantLabel: String) {
        cache[Self.key(modelID: modelID, quantLabel: quantLabel)] = info
        persist()
    }

    func remove(modelID: String, quantLabel: String) {
        cache.removeValue(forKey: Self.key(modelID: modelID, quantLabel: quantLabel))
        persist()
    }
}
