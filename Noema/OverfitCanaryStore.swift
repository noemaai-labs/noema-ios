import Foundation

struct OverfitCanaryRecord: Codable, Equatable, Sendable {
    let packageFingerprint: String
    let deviceModelIdentifier: String
    let volumeIdentifier: String
    let nativeContractVersion: Int
    let appBuild: String
    let completedAt: Date

    let storageAlignedReadMBps: Double
    let promptRate: Double
    let generationRate: Double
    let timeToFirstToken: TimeInterval
    let latency: OverfitLatencySample?
    let bankHitRate: Double
    let missesPerToken: Double
    let peakMemoryBytes: Int64
    let thermalStateRaw: Int
    let classification: OverfitFitClassification

    var storeKey: String {
        Self.key(fingerprint: packageFingerprint,
                 device: deviceModelIdentifier,
                 volume: volumeIdentifier,
                 contractVersion: nativeContractVersion,
                 appBuild: appBuild)
    }

    static func key(fingerprint: String, device: String, volume: String,
                    contractVersion: Int, appBuild: String) -> String {
        [fingerprint, device, volume, String(contractVersion), appBuild].joined(separator: "|")
    }
}

final class OverfitCanaryStore: @unchecked Sendable {
    static let shared = OverfitCanaryStore()

    // v2 invalidates records whose hit/miss values mixed prompt-prefill and
    // ordinary-decode counters. The record schema is unchanged; only the
    // measurement semantics are new.
    private static let storageKey = "overfitCanaryResults.v2"
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "noema.overfit.canary.store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(fingerprint: String, device: String, volume: String,
                contractVersion: Int, appBuild: String) -> OverfitCanaryRecord? {
        let key = OverfitCanaryRecord.key(fingerprint: fingerprint, device: device,
                                          volume: volume, contractVersion: contractVersion,
                                          appBuild: appBuild)
        return queue.sync { all()[key] }
    }

    func save(_ record: OverfitCanaryRecord) {
        queue.sync {
            var records = all()
            records[record.storeKey] = record
            persist(records)
        }
    }

    func removeAll(fingerprint: String) {
        queue.sync {
            var records = all()
            records = records.filter { $0.value.packageFingerprint != fingerprint }
            persist(records)
        }
    }

    private func all() -> [String: OverfitCanaryRecord] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: OverfitCanaryRecord].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: OverfitCanaryRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

enum OverfitEnvironmentIdentity {
    static var deviceModelIdentifier: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }

    /// Stable identity of the volume holding `url` (UUID when available,
    /// capacity fingerprint as a fallback for network/exotic mounts).
    static func volumeIdentifier(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeTotalCapacityKey])
        if let uuid = values?.volumeUUIDString, !uuid.isEmpty {
            return uuid
        }
        return "capacity:\(values?.volumeTotalCapacity ?? 0)"
    }

    static var appBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    static var nativeContractVersion: Int { 4 }
}
