import Foundation
import Darwin
import os

struct DeviceRAMInfo {
    let modelIdentifier: String
    let modelName: String
    let ram: String
    let limit: String
    let limitBytes: Int64?

    private static let cacheLock = OSAllocatedUnfairLock<DeviceRAMInfo?>(initialState: nil)

    /// Returns a per-app memory budget in bytes by subtracting 512 MiB
    /// from the detected limit, never going below zero. If `limitBytes` is unavailable,
    /// this parses the human-readable `limit` string. This is used for fit predictions.
    func conservativeLimitBytes() -> Int64? {
        let oneGiB: Int64 = 1024 * 1024 * 1024
        let reserve: Int64 = 512 * 1024 * 1024
        // Prefer explicit byte value if present
        if let b = limitBytes {
            return max(0, b - reserve)
        }
        // Fallback: parse from human-readable string like "~7 GB"
        let s = limit.replacingOccurrences(of: "~", with: "").lowercased()
        let digits = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
        guard let val = Double(digits) else { return nil }
        let parsed: Int64
        if s.contains("gb") {
            parsed = Int64(val * Double(oneGiB))
        } else if s.contains("mb") {
            parsed = Int64(val * 1024 * 1024)
        } else {
            parsed = Int64(val * Double(oneGiB))
        }
        return max(0, parsed - reserve)
    }

    static func current() -> DeviceRAMInfo {
        return cacheLock.withLock { state in
            if let existing = state { return existing }
            let info = computeCurrent()
            state = info
            return info
        }
    }

    /// Forces cache refresh, useful if storage conditions change (e.g. after migration).
    static func refreshCache() {
        cacheLock.withLock { state in
            state = computeCurrent()
        }
    }

    /// Ensures cache is populated as soon as convenient (app launch, etc.).
    static func primeCache() {
        _ = current()
    }

    private static func hardwareIdentifier() -> String {
#if os(macOS) || targetEnvironment(macCatalyst)
        if let model = macModelIdentifier() {
            return model
        }
#endif
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(cString: ptr)
            }
        }
    }

    private static func computeCurrent() -> DeviceRAMInfo {
        let identifier = Self.hardwareIdentifier()
        let storageTier = StorageTier.currentTier()
#if os(macOS) || targetEnvironment(macCatalyst)
        if identifier.lowercased().contains("mac") || identifier.lowercased().hasPrefix("j") {
            return computeMacInfo(identifier: identifier)
        }
#endif
        if let entry = resolvedEntry(for: identifier, storageTier: storageTier) {
            return DeviceRAMInfo(modelIdentifier: identifier, modelName: entry.name, ram: entry.ram, limit: entry.limit, limitBytes: entry.limitBytes)
        } else {
            let name = "Unknown (model: \(identifier))"
            return DeviceRAMInfo(modelIdentifier: identifier, modelName: name, ram: "Unknown RAM", limit: "--", limitBytes: nil)
        }
    }

#if os(macOS) || targetEnvironment(macCatalyst)
    private static func macModelIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func computeMacInfo(identifier: String) -> DeviceRAMInfo {
        let physicalBytes = Int64(ProcessInfo.processInfo.physicalMemory)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        let ramLabel = formatter.string(fromByteCount: physicalBytes)
        let budgetBytes = max(physicalBytes - (1_073_741_824), 0)
        let limitLabel = "~" + formatter.string(fromByteCount: budgetBytes)
        let name = Host.current().localizedName ?? "Mac (\(identifier))"
        return DeviceRAMInfo(modelIdentifier: identifier,
                             modelName: name,
                             ram: ramLabel,
                             limit: limitLabel,
                             limitBytes: budgetBytes)
    }
#endif

    private static func resolvedEntry(for identifier: String, storageTier: StorageTier?) -> (name: String, ram: String, limit: String, limitBytes: Int64?)? {
        guard let base = mapping[identifier] else { return nil }
        guard let storageTier,
              let override = storageOverrides[identifier]?[storageTier] else {
            return base
        }
        let limitBytes = override.limitBytes ?? base.limitBytes
        return (base.name, override.ram, override.limit, limitBytes)
    }

    private struct StorageOverride {
        let ram: String
        let limit: String
        let limitBytes: Int64?
    }

    private enum StorageTier: Int {
        case g64 = 64
        case g128 = 128
        case g256 = 256
        case g512 = 512
        case t1 = 1024
        case t2 = 2048

        private static func tier(forTotalBytes bytes: Int64) -> StorageTier? {
            let decimalGB = Double(bytes) / 1_000_000_000.0
            switch decimalGB {
            case ..<96: return .g64
            case ..<192: return .g128
            case ..<384: return .g256
            case ..<768: return .g512
            case ..<1536: return .t1
            case ..<3072: return .t2
            default: return nil
            }
        }

        static func currentTier() -> StorageTier? {
            do {
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
                if let totalBytes = (attributes[.systemSize] as? NSNumber)?.int64Value {
                    return tier(forTotalBytes: totalBytes)
                }
            } catch {
                // Ignore and fall back to default mapping
            }
            return nil
        }
    }

    private static let mapping: [String: (name: String, ram: String, limit: String, limitBytes: Int64?)] = [
        // iPhone X / XS / XR
        "iPhone10,3": ("iPhone X", "3–4 GB", "~2.5 GB", Int64(2500) * Int64(1024) * Int64(1024)),
        "iPhone10,6": ("iPhone X", "3–4 GB", "~2.5 GB", nil),
        "iPhone11,2": ("iPhone XS", "3–4 GB", "~2.5 GB", nil),
        "iPhone11,4": ("iPhone XS Max", "3–4 GB", "~2.5 GB", nil),
        "iPhone11,6": ("iPhone XS Max", "3–4 GB", "~2.5 GB", nil),
        "iPhone11,8": ("iPhone XR", "3–4 GB", "~2.5 GB", nil),

        // iPhone 11 & 12 series (non Pro)
        "iPhone12,1": ("iPhone 11", "4 GB", "~3 GB", nil),
        "iPhone12,3": ("iPhone 11 Pro", "4 GB", "~3 GB", nil),
        "iPhone12,5": ("iPhone 11 Pro Max", "4 GB", "~3 GB", nil),
        "iPhone13,1": ("iPhone 12 mini", "4 GB", "~3 GB", nil),
        "iPhone13,2": ("iPhone 12", "4 GB", "~3 GB", nil),

        // iPhone 12 Pro & later Pro models with 6 GB RAM
        "iPhone13,3": ("iPhone 12 Pro", "6 GB", "~5 GB", nil),
        "iPhone13,4": ("iPhone 12 Pro Max", "6 GB", "~5 GB", nil),
        "iPhone14,2": ("iPhone 13 Pro", "6 GB", "~5 GB", nil),
        "iPhone14,3": ("iPhone 13 Pro Max", "6 GB", "~5 GB", nil),
        "iPhone14,4": ("iPhone 13 mini", "4 GB", "~3 GB", nil),
        "iPhone14,5": ("iPhone 13", "4 GB", "~3 GB", nil),
        "iPhone14,6": ("iPhone SE (3rd generation, 2022)", "4 GB", "~3 GB", Int64(3000) * Int64(1024) * Int64(1024)),
        "iPhone14,7": ("iPhone 14", "6 GB", "~5 GB", nil),
        "iPhone14,8": ("iPhone 14 Plus", "6 GB", "~5 GB", nil),
        "iPhone15,2": ("iPhone 14 Pro", "6 GB", "~5 GB", nil),
        "iPhone15,3": ("iPhone 14 Pro Max", "6 GB", "~5 GB", nil),
        "iPhone15,4": ("iPhone 15", "6 GB", "~5 GB", nil),
        "iPhone15,5": ("iPhone 15 Plus", "6 GB", "~5 GB", nil),

        // 8 GB RAM devices
        "iPhone16,1": ("iPhone 15 Pro", "8 GB", "~7 GB", nil),
        "iPhone16,2": ("iPhone 15 Pro Max", "8 GB", "~7 GB", nil),
        "iPhone17,3": ("iPhone 16", "8 GB", "~7 GB", nil),
        "iPhone17,4": ("iPhone 16 Plus", "8 GB", "~7 GB", nil),
        "iPhone17,1": ("iPhone 16 Pro", "8 GB", "~7 GB", nil),
        "iPhone17,2": ("iPhone 16 Pro Max", "8 GB", "~7 GB", nil),
        "iPhone17,5": ("iPhone 16e", "8 GB", "~7 GB", Int64(7000) * Int64(1024) * Int64(1024)),
        "iPhone18,3": ("iPhone 17", "8 GB", "~7 GB", nil),
        "iPhone18,5": ("iPhone 17e", "8 GB", "~7 GB", nil),

        // 12 GB RAM devices
        "iPhone18,1": ("iPhone 17 Pro", "12 GB", "~11 GB", nil),
        "iPhone18,2": ("iPhone 17 Pro Max", "12 GB", "~11 GB", nil),
        "iPhone18,4": ("iPhone Air", "12 GB", "~11 GB", nil),
        
        // iPads that support iOS 17+ (starting from iPad Pro 2nd gen and newer)
        // iPad Pro 11" (all generations)
        "iPad8,1": ("iPad Pro 11\" (1st gen)", "4 GB", "~3 GB", nil),
        "iPad8,2": ("iPad Pro 11\" (1st gen)", "4 GB", "~3 GB", nil),
        "iPad8,3": ("iPad Pro 11\" (1st gen)", "6 GB", "~5 GB", nil),
        "iPad8,4": ("iPad Pro 11\" (1st gen)", "6 GB", "~5 GB", nil),
        "iPad8,9": ("iPad Pro 11\" (2nd gen)", "6 GB", "~5 GB", nil),
        "iPad8,10": ("iPad Pro 11\" (2nd gen)", "6 GB", "~5 GB", nil),
        "iPad13,4": ("iPad Pro 11\" (3rd gen)", "8 GB", "~7 GB", nil),
        "iPad13,5": ("iPad Pro 11\" (3rd gen)", "8 GB", "~7 GB", nil),
        "iPad13,6": ("iPad Pro 11\" (3rd gen)", "8 GB", "~7 GB", nil),
        "iPad13,7": ("iPad Pro 11\" (3rd gen)", "8 GB", "~7 GB", nil),
        "iPad14,3": ("iPad Pro 11\" (4th gen)", "8 GB", "~7 GB", nil),
        "iPad14,4": ("iPad Pro 11\" (4th gen)", "8 GB", "~7 GB", nil),
        "iPad16,3": ("iPad Pro 11\" (5th gen, M4)", "8 GB", "~7 GB", nil),
        "iPad16,4": ("iPad Pro 11\" (5th gen, M4)", "8 GB", "~7 GB", nil),
        
        // iPad Pro 12.9" (3rd gen and newer support iOS 17+)
        "iPad8,5": ("iPad Pro 12.9\" (3rd gen)", "4 GB", "~3 GB", nil),
        "iPad8,6": ("iPad Pro 12.9\" (3rd gen)", "4 GB", "~3 GB", nil),
        "iPad8,7": ("iPad Pro 12.9\" (3rd gen)", "6 GB", "~5 GB", nil),
        "iPad8,8": ("iPad Pro 12.9\" (3rd gen)", "6 GB", "~5 GB", nil),
        "iPad8,11": ("iPad Pro 12.9\" (4th gen)", "6 GB", "~5 GB", nil),
        "iPad8,12": ("iPad Pro 12.9\" (4th gen)", "6 GB", "~5 GB", nil),
        "iPad13,8": ("iPad Pro 12.9\" (5th gen)", "8 GB", "~7 GB", nil),
        "iPad13,9": ("iPad Pro 12.9\" (5th gen)", "8 GB", "~7 GB", nil),
        "iPad13,10": ("iPad Pro 12.9\" (5th gen)", "8 GB", "~7 GB", nil),
        "iPad13,11": ("iPad Pro 12.9\" (5th gen)", "8 GB", "~7 GB", nil),
        "iPad14,5": ("iPad Pro 12.9\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad14,6": ("iPad Pro 12.9\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad16,5": ("iPad Pro 13\" (M4)", "8 GB", "~7 GB", nil),
        "iPad16,6": ("iPad Pro 13\" (M4)", "8 GB", "~7 GB", nil),
        
        // iPad Air (3rd gen and newer)
        "iPad11,3": ("iPad Air (3rd gen)", "3 GB", "~2.5 GB", nil),
        "iPad11,4": ("iPad Air (3rd gen)", "3 GB", "~2.5 GB", nil),
        "iPad13,1": ("iPad Air (4th gen)", "4 GB", "~3 GB", nil),
        "iPad13,2": ("iPad Air (4th gen)", "4 GB", "~3 GB", nil),
        "iPad13,16": ("iPad Air (5th gen)", "8 GB", "~7 GB", nil),
        "iPad13,17": ("iPad Air (5th gen)", "8 GB", "~7 GB", nil),
        "iPad14,8": ("iPad Air 11\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad14,9": ("iPad Air 11\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad14,10": ("iPad Air 13\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad14,11": ("iPad Air 13\" (6th gen)", "8 GB", "~7 GB", nil),
        "iPad16,8": ("iPad Air 11-inch (M4, Wi-Fi)", "12 GB", "~11 GB", nil),
        "iPad16,9": ("iPad Air 11-inch (M4, Cellular)", "12 GB", "~11 GB", nil),
        "iPad16,10": ("iPad Air 13-inch (M4, Wi-Fi)", "12 GB", "~11 GB", nil),
        "iPad16,11": ("iPad Air 13-inch (M4, Cellular)", "12 GB", "~11 GB", nil),
        
        // iPad (7th gen and newer)
        "iPad7,11": ("iPad (7th gen)", "3 GB", "~2.5 GB", nil),
        "iPad7,12": ("iPad (7th gen)", "3 GB", "~2.5 GB", nil),
        "iPad11,6": ("iPad (8th gen)", "3 GB", "~2.5 GB", nil),
        "iPad11,7": ("iPad (8th gen)", "3 GB", "~2.5 GB", nil),
        "iPad12,1": ("iPad (9th gen)", "3 GB", "~2.5 GB", nil),
        "iPad12,2": ("iPad (9th gen)", "3 GB", "~2.5 GB", nil),
        "iPad13,18": ("iPad (10th gen)", "4 GB", "~3 GB", nil),
        "iPad13,19": ("iPad (10th gen)", "4 GB", "~3 GB", nil),
        
        // iPad mini (5th gen and newer)
        "iPad11,1": ("iPad mini (5th gen)", "3 GB", "~2.5 GB", nil),
        "iPad11,2": ("iPad mini (5th gen)", "3 GB", "~2.5 GB", nil),
        "iPad14,1": ("iPad mini (6th gen)", "4 GB", "~3 GB", nil),
        "iPad14,2": ("iPad mini (6th gen)", "4 GB", "~3 GB", nil),

        // Apple Vision Pro
        "RealityDevice14,1": ("Apple Vision Pro", "16 GB", "~15 GB", Int64(15_000) * Int64(1024) * Int64(1024))
    ]

    private static let storageOverrides: [String: [StorageTier: StorageOverride]] = {
        let highRAMOverride = StorageOverride(
            ram: "16 GB",
            limit: "~15 GB",
            limitBytes: Int64(15_000) * Int64(1024) * Int64(1024)
        )
        let highRAM: [StorageTier: StorageOverride] = [
            .t1: highRAMOverride,
            .t2: highRAMOverride
        ]

        var overrides: [String: [StorageTier: StorageOverride]] = [:]

        let m1Pro11 = ["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7"]
        let m1Pro129 = ["iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11"]
        let m2Pro11 = ["iPad14,3", "iPad14,4"]
        let m2Pro129 = ["iPad14,5", "iPad14,6"]
        let m4Pro11 = ["iPad16,3", "iPad16,4"]
        let m4Pro13 = ["iPad16,5", "iPad16,6"]

        (m1Pro11 + m1Pro129 + m2Pro11 + m2Pro129 + m4Pro11 + m4Pro13).forEach { identifier in
            overrides[identifier] = highRAM
        }

        return overrides
    }()
}
