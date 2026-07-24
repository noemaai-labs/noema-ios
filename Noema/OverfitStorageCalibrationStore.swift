import Foundation
import Darwin

struct OverfitStorageCalibrationRecord: Codable, Equatable, Sendable {
    let deviceModelIdentifier: String
    let volumeIdentifier: String
    /// F_NOCACHE aligned-read bandwidth. Keeps its pre-dual-pass name:
    /// records written before the cached pass existed stored this same
    /// measurement here, so old data decodes into the right field.
    let alignedReadMBps: Double
    /// Same benchmark through the default (page-cache) read path; nil on
    /// records written before the dual-pass benchmark existed.
    let cachedReadMBps: Double?
    let sampleBytes: Int64
    let sampledAt: Date

    var storeKey: String {
        Self.key(device: deviceModelIdentifier, volume: volumeIdentifier)
    }

    static func key(device: String, volume: String) -> String {
        [device, volume].joined(separator: "|")
    }
}

final class OverfitStorageCalibrationStore: @unchecked Sendable {
    static let shared = OverfitStorageCalibrationStore()

    private static let storageKey = "overfitStorageCalibration.v1"
    private static let noCacheDecisionKey = "overfitStorageNoCacheDecision.v1"
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "noema.overfit.storage.calibration")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(device: String, volume: String) -> OverfitStorageCalibrationRecord? {
        let key = OverfitStorageCalibrationRecord.key(device: device, volume: volume)
        return queue.sync { all()[key] }
    }

    func save(_ record: OverfitStorageCalibrationRecord) {
        queue.sync {
            var records = all()
            records[record.storeKey] = record
            persist(records)
        }
    }

    private func all() -> [String: OverfitStorageCalibrationRecord] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: OverfitStorageCalibrationRecord].self, from: data)) ?? [:]
    }

    private func persist(_ records: [String: OverfitStorageCalibrationRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - F_NOCACHE launch decision

    /// Env var the native paged runtime samples at configure time each boot.
    static let noCacheEnvironmentKey = "NOEMA_PAGED_NOCACHE"
    /// Turn the bypass on only when it clearly wins (>15%)…
    static let noCacheEnableRatio = 1.15
    /// …and back off only when the advantage has clearly gone (<5%), so
    /// borderline re-measurements never flap the mode between launches.
    static let noCacheDisableRatio = 1.05

    /// Sticky per-volume decision with hysteresis. Records without a cached
    /// pass (legacy shape) and missing records keep the last decision —
    /// default off — instead of re-deciding on partial data.
    func shouldUseNoCache(device: String, volume: String) -> Bool {
        let key = OverfitStorageCalibrationRecord.key(device: device, volume: volume)
        return queue.sync {
            let previous = decisions()[key] ?? false
            guard let record = all()[key],
                  let cached = record.cachedReadMBps,
                  cached > 0, record.alignedReadMBps > 0 else {
                return previous
            }
            let ratio = record.alignedReadMBps / cached
            let decision = previous
                ? ratio >= Self.noCacheDisableRatio
                : ratio > Self.noCacheEnableRatio
            if decision != previous {
                var updated = decisions()
                updated[key] = decision
                persistDecisions(updated)
            }
            return decision
        }
    }

    /// Exports (or clears) NOEMA_PAGED_NOCACHE for the next paged boot.
    /// Must run before LlamaServerBridge starts the server: the native
    /// runtime samples the variable when it configures for that boot.
    func applyNoCacheEnvironment(packageDirectory: URL) {
        let use = shouldUseNoCache(
            device: OverfitEnvironmentIdentity.deviceModelIdentifier,
            volume: OverfitEnvironmentIdentity.volumeIdentifier(for: packageDirectory)
        )
        if use {
            setenv(Self.noCacheEnvironmentKey, "1", 1)
        } else {
            unsetenv(Self.noCacheEnvironmentKey)
        }
    }

    private func decisions() -> [String: Bool] {
        guard let data = defaults.data(forKey: Self.noCacheDecisionKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    private func persistDecisions(_ decisions: [String: Bool]) {
        if let data = try? JSONEncoder().encode(decisions) {
            defaults.set(data, forKey: Self.noCacheDecisionKey)
        }
    }

    // MARK: - Microbenchmark

    struct AlignedReadSample: Equatable, Sendable {
        let megabytesPerSecond: Double
        let bytesRead: Int64
    }

    /// One pass per read path over the same file. The nocache pass runs
    /// first — F_NOCACHE reads do not populate the unified buffer cache, so
    /// they cannot warm the cached pass — and the cached pass samples
    /// half-stride-shifted offsets so it reads regions the benchmark itself
    /// has not touched.
    struct DualAlignedReadSample: Equatable, Sendable {
        let nocache: AlignedReadSample
        let cached: AlignedReadSample
    }

    enum MicrobenchmarkError: LocalizedError, Equatable {
        case openFailed(errno: Int32)
        case emptyFile
        case bufferAllocationFailed
        case readFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .openFailed(let code): return "storage microbenchmark could not open the file (errno \(code))"
            case .emptyFile: return "storage microbenchmark target file is empty"
            case .bufferAllocationFailed: return "storage microbenchmark could not allocate an aligned buffer"
            case .readFailed(let code): return "storage microbenchmark read failed (errno \(code))"
            }
        }
    }

    static let defaultSampleBytes = 64 * 1024 * 1024

    static func measureAlignedReadMBps(
        fileURL: URL,
        alignment: Int = 16 * 1024,
        sampleBytes: Int = defaultSampleBytes
    ) throws -> Double {
        try sampleAlignedRead(fileURL: fileURL, alignment: alignment, sampleBytes: sampleBytes)
            .megabytesPerSecond
    }

    static func sampleAlignedReadDual(
        fileURL: URL,
        alignment: Int = 16 * 1024,
        sampleBytes: Int = defaultSampleBytes
    ) throws -> DualAlignedReadSample {
        let nocache = try sampleAlignedRead(
            fileURL: fileURL,
            alignment: alignment,
            sampleBytes: sampleBytes,
            bypassPageCache: true,
            offsetPhase: 0
        )
        let cached = try sampleAlignedRead(
            fileURL: fileURL,
            alignment: alignment,
            sampleBytes: sampleBytes,
            bypassPageCache: false,
            offsetPhase: 0.5
        )
        return DualAlignedReadSample(nocache: nocache, cached: cached)
    }

    /// Page-aligned pread over offsets spread across the whole file, so the
    /// number is not skewed by a fast or slow region at the head of the
    /// file. With bypassPageCache (the default, and the historical behavior)
    /// F_NOCACHE keeps the unified buffer cache out of the measurement;
    /// without it the same reads go through the default cached path.
    /// offsetPhase shifts every sample by that fraction of the inter-sample
    /// stride, letting a second pass avoid the first pass's exact extents.
    static func sampleAlignedRead(
        fileURL: URL,
        alignment: Int = 16 * 1024,
        sampleBytes: Int = defaultSampleBytes,
        bypassPageCache: Bool = true,
        offsetPhase: Double = 0
    ) throws -> AlignedReadSample {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw MicrobenchmarkError.openFailed(errno: errno) }
        defer { close(fd) }
        if bypassPageCache {
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw MicrobenchmarkError.openFailed(errno: errno) }
        let fileSize = Int64(info.st_size)
        guard fileSize > 0 else { throw MicrobenchmarkError.emptyFile }

        // Page alignment is what F_NOCACHE reads want; anything smaller than a
        // page defeats the point of an "aligned read" number.
        let pageSize = Int(getpagesize())
        let align = max(pageSize, alignment)
        let chunkSize = Int(min(Int64(max(align, 1024 * 1024)), fileSize))

        var buffer: UnsafeMutableRawPointer?
        guard posix_memalign(&buffer, align, chunkSize) == 0, let buffer else {
            throw MicrobenchmarkError.bufferAllocationFailed
        }
        defer { free(buffer) }

        let targetBytes = min(Int64(max(chunkSize, sampleBytes)), fileSize)
        let sampleCount = max(1, Int(targetBytes / Int64(chunkSize)))
        // Deterministic offsets spread over the readable range, rounded down
        // to the alignment so every pread is aligned on both sides.
        let readableSpan = fileSize - Int64(chunkSize)
        let stride = sampleCount > 1 ? readableSpan / Int64(sampleCount - 1) : readableSpan
        let shift = Int64(offsetPhase * Double(stride))
        var offsets: [Int64] = []
        offsets.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let base = sampleCount == 1
                ? 0
                : readableSpan * Int64(index) / Int64(sampleCount - 1)
            let raw = min(base + shift, readableSpan)
            offsets.append((raw / Int64(align)) * Int64(align))
        }

        var bytesRead: Int64 = 0
        let started = DispatchTime.now()
        for offset in offsets {
            var chunkRemaining = chunkSize
            var chunkOffset = offset
            while chunkRemaining > 0 {
                let n = pread(fd, buffer, chunkRemaining, chunkOffset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MicrobenchmarkError.readFailed(errno: errno)
                }
                if n == 0 { break }
                bytesRead += Int64(n)
                chunkRemaining -= n
                chunkOffset += Int64(n)
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000.0
        guard bytesRead > 0 else { throw MicrobenchmarkError.readFailed(errno: 0) }
        let seconds = max(elapsed, 1e-6)
        return AlignedReadSample(
            megabytesPerSecond: Double(bytesRead) / seconds / 1_000_000.0,
            bytesRead: bytesRead
        )
    }
}
