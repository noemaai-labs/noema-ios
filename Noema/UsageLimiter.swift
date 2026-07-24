import Foundation
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#endif
import Darwin

public struct UsageLimiterConfig {
    public var limitPer24h: Int = 5
    public var minIntervalSeconds: TimeInterval = 45
    /// Optional product identifier for a subscription that grants unlimited quota
    public var proProductID: String?
    public var service: String
    public var account: String
    public var appGroupID: String

    public init(limitPer24h: Int = 5,
                minIntervalSeconds: TimeInterval = 45,
                service: String,
                account: String,
                appGroupID: String) {
        self.proProductID = nil
        self.limitPer24h = limitPer24h
        self.minIntervalSeconds = minIntervalSeconds
        self.service = service
        self.account = account
        self.appGroupID = appGroupID
    }
}

public enum ConsumeResult: Equatable {
    case consumed
    case throttledCooldown(until: Date)
    case limitReached(until: Date)
}

public enum UsageLimiterError: Error, Equatable {
    case corruptedState
    case keychainFailure(OSStatus)
    case ioFailure
    case integrityCheckFailed
}

public protocol TimeProvider: Sendable {
    func now() -> Date
    func uptimeSeconds() -> TimeInterval
    func currentIDFV() -> String?
}

public struct SystemTimeProvider: TimeProvider {
    public init() {}
    public func now() -> Date { Date() }
    public func uptimeSeconds() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func currentIDFV() -> String? {
#if canImport(UIKit)
        // Access UIDevice.identifierForVendor via Objective-C runtime to avoid main-actor isolation warnings.
        guard let uidClass: AnyClass = NSClassFromString("UIDevice") else { return nil }
        let selectorCurrent = NSSelectorFromString("currentDevice")
        guard let clsAsNSObjectType = uidClass as? NSObject.Type,
              let currentUnmanaged = clsAsNSObjectType.perform(selectorCurrent) else { return nil }
        let current = currentUnmanaged.takeUnretainedValue()
        let selIDFV = NSSelectorFromString("identifierForVendor")
        guard let idfvUnmanaged = (current as AnyObject).perform(selIDFV) else { return nil }
        let idfvObj = idfvUnmanaged.takeUnretainedValue()
        if let uuid = idfvObj as? UUID { return uuid.uuidString }
        if let nsuuid = idfvObj as? NSUUID { return nsuuid.uuidString }
        return nil
#else
        return nil
#endif
    }
}

/// Lightweight environment heuristics. In Release builds we harden behavior if any flags are true.
struct EnvironmentHints {
    var isDebuggerOrTTYAttached: Bool
    var writableOutsideSandbox: Bool
    var hasCydia: Bool

    var shouldHarden: Bool { isDebuggerOrTTYAttached || writableOutsideSandbox || hasCydia }
}

public final class UsageLimiter: @unchecked Sendable {
    private let config: UsageLimiterConfig
    private let time: TimeProvider
    private let queue: DispatchQueue
    private let environment: EnvironmentHints
    private let fileURLOverride: URL?

    // Session-scoped state
    private var tamperCooldownUntilEpoch: Int?
    private var strictSessionActive: Bool = false

    // MARK: Init
    public init(config: UsageLimiterConfig, timeProvider: TimeProvider = SystemTimeProvider()) throws {
        self.config = config
        self.time = timeProvider
        self.queue = DispatchQueue(label: "UsageLimiter.serial.\(config.service).\(config.account)", qos: .userInitiated)
        self.environment = Self.detectEnvironment()
        self.fileURLOverride = nil
        // Ensure secret key exists up-front so init can fail early if Keychain is unavailable
        _ = try Self.ensureSecretKey(service: config.service, account: Self.secretAccount(for: config.account))
        // Best-effort: warm up state file directory
        _ = self.stateFileURL()
        // RevenueCat integration: pro status is managed externally via SettingsStore; no StoreKit polling here.
    }

    /// Internal-only initializer to support tests by overriding the mirror file URL.
    /// Not part of the public API.
    init(config: UsageLimiterConfig, timeProvider: TimeProvider, fileMirrorURLOverride: URL?) throws {
        self.config = config
        self.time = timeProvider
        self.queue = DispatchQueue(label: "UsageLimiter.serial.\(config.service).\(config.account)", qos: .userInitiated)
        self.environment = Self.detectEnvironment()
        self.fileURLOverride = fileMirrorURLOverride
        // Ensure secret key exists up-front so init can fail early if Keychain is unavailable
        _ = try Self.ensureSecretKey(service: config.service, account: Self.secretAccount(for: config.account))
        // Best-effort: warm up state file directory
        _ = self.stateFileURL()
        // RevenueCat integration: pro status is managed externally via SettingsStore; no StoreKit polling here.
    }

    // MARK: Public API (thread-safe)
    public func canConsume(now: Date = .init()) -> Bool {
        return queue.sync {
            do {
                let loaded = try loadState(now: now)
                if loaded.integrityFailed { return false }
                if loaded.isTampered || isInTamperCooldown(nowEpoch: Int(now.timeIntervalSince1970)) {
                    return false
                }
                // If pro subscription is active, unlimited
                if isProActive(state: loaded.state) { return true }
                let eval = evaluateEligibility(state: loaded.state, now: now, uptimeSec: time.uptimeSeconds())
                switch eval.result {
                case .consumed:
                    // evaluateEligibility returns .consumed to indicate both gates pass; but do not persist
                    return true
                case .throttledCooldown:
                    return false
                case .limitReached:
                    return false
                }
            } catch {
                // On any error, be safe: disallow.
                return false
            }
        }
    }

    @discardableResult
    public func consume(now: Date = .init()) throws -> ConsumeResult {
        return try queue.sync {
            let loaded = try loadState(now: now)
            if loaded.integrityFailed {
                try enterTamperCooldown(now: now)
                // We may have restored from a valid mirror; signal detection to caller
                throw UsageLimiterError.integrityCheckFailed
            }
            if loaded.isTampered || isInTamperCooldown(nowEpoch: Int(now.timeIntervalSince1970)) {
                try enterTamperCooldown(now: now)
                return .limitReached(until: now.addingTimeInterval(86_400))
            }
            if isProActive(state: loaded.state) { return .consumed }

            var state = loaded.state

            // Evaluate gates
            let eval = evaluateEligibility(state: state, now: now, uptimeSec: time.uptimeSeconds())
            switch eval.result {
            case .consumed:
                // Append and persist
                let nowEpoch = Int(now.timeIntervalSince1970)
                state.stamps = eval.prunedStamps
                state.stamps.append(nowEpoch)
                state.lastSeenWallClock = nowEpoch
                state.lastSeenUptimeMillis = Int(time.uptimeSeconds() * 1000)
                state.lastSeenIDFV = time.currentIDFV()
                // strict mode management
                if eval.strictModeShouldActivate {
                    let until = max(state.strictModeUntil ?? 0, nowEpoch + 86_400)
                    state.strictModeUntil = until
                    strictSessionActive = true
                } else if let until = state.strictModeUntil {
                    if nowEpoch >= until {
                        state.strictModeUntil = nil
                        strictSessionActive = false
                    } else if !eval.isClockBackwards {
                        // Realigned early
                        state.strictModeUntil = nil
                        strictSessionActive = false
                    }
                }
                try persist(state: state)
                return .consumed
            case .throttledCooldown(let until):
                return .throttledCooldown(until: until)
            case .limitReached(let until):
                return .limitReached(until: until)
            }
        }
    }

    public func remaining(now: Date = .init()) -> Int {
        return queue.sync {
            do {
                let loaded = try loadState(now: now)
                if loaded.integrityFailed { return 0 }
                if loaded.isTampered || isInTamperCooldown(nowEpoch: Int(now.timeIntervalSince1970)) {
                    return 0
                }
                let result = remainingCount(state: loaded.state, now: now)
                return max(0, result)
            } catch {
                return 0
            }
        }
    }

    public func nextEligibleDate(now: Date = .init()) -> Date? {
        return queue.sync {
            do {
                let loaded = try loadState(now: now)
                if loaded.integrityFailed { return now.addingTimeInterval(86_400) }
                if loaded.isTampered || isInTamperCooldown(nowEpoch: Int(now.timeIntervalSince1970)) {
                    return now.addingTimeInterval(86_400)
                }
                return computeNextEligibleDate(state: loaded.state, now: now)
            } catch {
                return now.addingTimeInterval(86_400)
            }
        }
    }

    // MARK: - Core evaluation
    private struct EligibilityEval {
        let result: ConsumeResult
        let prunedStamps: [Int]
        let strictModeShouldActivate: Bool
        let isClockBackwards: Bool
    }

    private func evaluateEligibility(state: WireState, now: Date, uptimeSec: TimeInterval) -> EligibilityEval {
        let nowEpoch = Int(now.timeIntervalSince1970)
        let windowStart = nowEpoch - 86_400
        var pruned = state.stamps.filter { $0 >= windowStart }

        // Clock tamper detection relative to monotonic time
        let wallDelta = Double(nowEpoch - state.lastSeenWallClock)
        let upDelta = uptimeSec - Double(state.lastSeenUptimeMillis) / 1000.0
        let clockBackwards = (wallDelta + 300.0) < upDelta

        var isStrictModeActive = strictSessionActive
        if let until = state.strictModeUntil, nowEpoch < until {
            isStrictModeActive = true
        }
        // Immediate activation if clock is detected going backwards
        if clockBackwards { isStrictModeActive = true }
        let strictModeShouldActivate = clockBackwards

        let effectiveMinInterval = effectiveMinIntervalSeconds()

        if isStrictModeActive {
            // Calendar-day cap
            let dayKey = Self.dayKey(for: now)
            let calendar = Calendar.current
            let dayCount = pruned.filter { stamp in
                if let d = Date(timeIntervalSince1970: TimeInterval(stamp)) as Date? {
                    return Self.dayKey(for: d) == dayKey
                }
                return false
            }.count
            if dayCount >= config.limitPer24h {
                let startOfNextDay = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .strict, direction: .forward) ?? now.addingTimeInterval(86_400)
                return EligibilityEval(result: .limitReached(until: startOfNextDay), prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
            }
            // Still enforce min interval strictly
            if let last = pruned.last {
                let next = TimeInterval(last) + effectiveMinInterval
                if TimeInterval(nowEpoch) < next {
                    return EligibilityEval(result: .throttledCooldown(until: Date(timeIntervalSince1970: next)), prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
                }
            }
            return EligibilityEval(result: .consumed, prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
        } else {
            // Gate A: min interval
            if let last = pruned.last {
                let next = TimeInterval(last) + effectiveMinInterval
                if TimeInterval(nowEpoch) < next {
                    return EligibilityEval(result: .throttledCooldown(until: Date(timeIntervalSince1970: next)), prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
                }
            }
            // Gate B: rolling window total
            if pruned.count >= config.limitPer24h {
                if let earliest = pruned.first {
                    let until = Date(timeIntervalSince1970: TimeInterval(earliest + 86_400))
                    return EligibilityEval(result: .limitReached(until: until), prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
                } else {
                    return EligibilityEval(result: .limitReached(until: now.addingTimeInterval(86_400)), prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
                }
            }
            return EligibilityEval(result: .consumed, prunedStamps: pruned, strictModeShouldActivate: strictModeShouldActivate, isClockBackwards: clockBackwards)
        }
    }

    private func remainingCount(state: WireState, now: Date) -> Int {
        let nowEpoch = Int(now.timeIntervalSince1970)
        let windowStart = nowEpoch - 86_400
        let pruned = state.stamps.filter { $0 >= windowStart }
        var isStrictModeActive = strictSessionActive
        if let until = state.strictModeUntil, nowEpoch < until {
            isStrictModeActive = true
        }
        if isStrictModeActive {
            let dayKey = Self.dayKey(for: now)
            let dayCount = pruned.filter { stamp in
                Self.dayKey(for: Date(timeIntervalSince1970: TimeInterval(stamp))) == dayKey
            }.count
            return config.limitPer24h - dayCount
        } else {
            return config.limitPer24h - pruned.count
        }
    }

    private func computeNextEligibleDate(state: WireState, now: Date) -> Date? {
        let nowEpoch = Int(now.timeIntervalSince1970)
        let windowStart = nowEpoch - 86_400
        let pruned = state.stamps.filter { $0 >= windowStart }
        let effectiveMinInterval = effectiveMinIntervalSeconds()

        var isStrictModeActive = strictSessionActive
        if let until = state.strictModeUntil, nowEpoch < until {
            isStrictModeActive = true
        }
        if isStrictModeActive {
            let calendar = Calendar.current
            let dayKey = Self.dayKey(for: now)
            let dayCount = pruned.filter { stamp in
                Self.dayKey(for: Date(timeIntervalSince1970: TimeInterval(stamp))) == dayKey
            }.count
            if dayCount >= config.limitPer24h {
                let startOfNextDay = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .strict, direction: .forward) ?? now.addingTimeInterval(86_400)
                return startOfNextDay
            }
            if let last = pruned.last {
                let next = TimeInterval(last) + effectiveMinInterval
                if TimeInterval(nowEpoch) < next {
                    return Date(timeIntervalSince1970: next)
                }
            }
            return nil
        } else {
            var candidates: [Date] = []
            if let last = pruned.last {
                let next = TimeInterval(last) + effectiveMinInterval
                if TimeInterval(nowEpoch) < next {
                    candidates.append(Date(timeIntervalSince1970: next))
                }
            }
            if pruned.count >= config.limitPer24h, let earliest = pruned.first {
                candidates.append(Date(timeIntervalSince1970: TimeInterval(earliest + 86_400)))
            }
            return candidates.min()
        }
    }

    // MARK: - Persistence
    private struct Loaded {
        let state: WireState
        let isTampered: Bool
        let integrityFailed: Bool
        let usedSource: String
        let key: Data
    }

    private func loadState(now: Date) throws -> Loaded {
        let nowEpoch = Int(now.timeIntervalSince1970)
        let secretKey = try Self.ensureSecretKey(service: config.service, account: Self.secretAccount(for: config.account))

        // Load tamper cooldown marker if any
        if tamperCooldownUntilEpoch == nil {
            if let data = try KeychainStore.read(service: config.service, account: Self.tamperAccount(for: config.account)), data.count >= 8 {
                let rawUntil = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
                tamperCooldownUntilEpoch = Int(Int64(littleEndian: rawUntil))
            }
        }

        // Read both stores
        let keychainData = try KeychainStore.read(service: config.service, account: config.account)
        var keychainState: WireState? = nil
        var keychainDataInvalid = false
        if let kc = keychainData {
            keychainState = StateCodec.decodeIfValid(kc, secretKey: secretKey)
            if keychainState == nil {
                keychainDataInvalid = true
            }
        }

        let fileURL = stateFileURL()
        var fileData: Data? = nil
        var fileState: WireState? = nil
        if let url = fileURL {
            fileData = try? Data(contentsOf: url)
            if let fd = fileData {
                fileState = StateCodec.decodeIfValid(fd, secretKey: secretKey)
            }
        }

        // Environment hardening: in Release, if hardened, prefer Keychain only; refuse file restore when Keychain invalid/missing
        #if !DEBUG
        if environment.shouldHarden {
            if let ks = keychainState {
                return Loaded(state: ks, isTampered: false, integrityFailed: false, usedSource: "keychain", key: secretKey)
            }
            // No KC state: initialize fresh; refuse file restoration in hardened env
            var state = Self.freshWireState(now: now, time: time)
            state.lastSeenIDFV = time.currentIDFV()
            try persist(state: state)
            return Loaded(state: state, isTampered: false, integrityFailed: false, usedSource: "fresh", key: secretKey)
        }
        #endif

        // Normal path: choose newest valid source; support anti-reinstall via IDFV
        if keychainState == nil && fileState == nil {
            var fresh = Self.freshWireState(now: now, time: time)
            fresh.lastSeenIDFV = time.currentIDFV()
            try persist(state: fresh)
            return Loaded(state: fresh, isTampered: false, integrityFailed: false, usedSource: "fresh", key: secretKey)
        }

        if let ks = keychainState, let fs = fileState {
            // both valid: pick newest by lastSeenWallClock
            let chosen = (ks.lastSeenWallClock >= fs.lastSeenWallClock) ? ks : fs
            if let url = fileURL, let data = try? StateCodec.encode(chosen, secretKey: secretKey) {
                // Keep them in sync (best-effort)
                try? KeychainStore.write(service: config.service, account: config.account, data: data)
                try? writeFileAtomically(url: url, data: data)
            }
            return Loaded(state: chosen, isTampered: false, integrityFailed: false, usedSource: (chosen.lastSeenWallClock == ks.lastSeenWallClock ? "keychain" : "file"), key: secretKey)
        }

        if let ks = keychainState {
            // KC valid only
            // If file exists and differs, repair it
            if let url = fileURL, let data = try? StateCodec.encode(ks, secretKey: secretKey) {
                try? writeFileAtomically(url: url, data: data)
            }
            return Loaded(state: ks, isTampered: false, integrityFailed: false, usedSource: "keychain", key: secretKey)
        }

        if let fs = fileState {
            // KC missing or invalid but file valid. Anti-reinstall hint: only treat as restore if IDFV matches current
            let currentIDFV = time.currentIDFV()
            let brandNewKC = (keychainData == nil)
            if brandNewKC || keychainDataInvalid {
                if fs.lastSeenIDFV != nil && fs.lastSeenIDFV == currentIDFV {
                    // Restore Keychain from file
                    if let data = try? StateCodec.encode(fs, secretKey: secretKey) {
                        try KeychainStore.write(service: config.service, account: config.account, data: data)
                    }
                    // Signal integrity failure when Keychain data was invalid
                    return Loaded(state: fs, isTampered: false, integrityFailed: keychainDataInvalid, usedSource: brandNewKC ? "file-restore" : "file-repair", key: secretKey)
                } else if brandNewKC {
                    // Treat as fresh
                    var fresh = Self.freshWireState(now: now, time: time)
                    fresh.lastSeenIDFV = currentIDFV
                    try persist(state: fresh)
                    return Loaded(state: fresh, isTampered: false, integrityFailed: false, usedSource: "fresh", key: secretKey)
                }
            }
        }

        // If we get here, we had invalid Keychain and no valid file to restore => tampered
        if keychainDataInvalid {
            return Loaded(state: Self.freshWireState(now: now, time: time), isTampered: true, integrityFailed: true, usedSource: "keychain-invalid", key: secretKey)
        }

        // Fallback
        var fallback = Self.freshWireState(now: now, time: time)
        fallback.lastSeenIDFV = time.currentIDFV()
        // Preserve any pro flag from file if present
        if let fs = fileState {
            fallback.lastSeenPro = fs.lastSeenPro
        }
        try persist(state: fallback)
        return Loaded(state: fallback, isTampered: false, integrityFailed: false, usedSource: "fallback-fresh", key: secretKey)
    }

    private func persist(state: WireState) throws {
        let secretKey = try Self.ensureSecretKey(service: config.service, account: Self.secretAccount(for: config.account))
        let data = try StateCodec.encode(state, secretKey: secretKey)
        try KeychainStore.write(service: config.service, account: config.account, data: data)
        if let url = stateFileURL() {
            try writeFileAtomically(url: url, data: data)
        }
        // If proProductID is configured, persist a marker for pro status via lastSeenPro
        if let pid = config.proProductID {
            // Best-effort: check StoreKit2 for subscription entitlement. Keep optional to avoid importing StoreKit in this tiny library.
            // The host app may update `lastSeenPro` by calling a separate helper if desired; by default we won't auto-detect here.
            _ = pid
        }
    }

    private func writeFileAtomically(url: URL, data: Data) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // Foundation's atomic write performs a same-directory replace,
            // avoiding the remove-then-move window where a crash could leave
            // the limiter with no mirror state at all.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw UsageLimiterError.ioFailure
        }
    }

    private func stateFileURL() -> URL? {
        if let override = fileURLOverride { return override }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: config.appGroupID) else {
            return nil
        }
        return container.appendingPathComponent("UsageLimiter", isDirectory: true).appendingPathComponent("state.dat", isDirectory: false)
    }

    // MARK: - Pro subscription helper
    /// Host app can call this to mark the local state as pro (unlimited).
    /// This does not verify receipts; it's a convenience for apps that perform entitlement checks elsewhere.
    public func markPro(_ enabled: Bool, now: Date = .init()) throws {
        try queue.sync {
            var loaded = try loadState(now: now)
            var s = loaded.state
            s.lastSeenPro = enabled
            s.lastSeenWallClock = Int(now.timeIntervalSince1970)
            s.lastSeenUptimeMillis = Int(time.uptimeSeconds() * 1000)
            try persist(state: s)
        }
    }

    private func isProActive(state: WireState) -> Bool {
        // Host app controls pro via external entitlement checks; persist lastSeenPro flag only.
        return state.lastSeenPro ?? false
    }

    // (Removed) StoreKit integration: handled by host app via RevenueCat

    private static func ensureSecretKey(service: String, account: String) throws -> Data {
        if let data = try KeychainStore.read(service: service, account: account) {
            return data
        }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw UsageLimiterError.keychainFailure(status) }
        try KeychainStore.write(service: service, account: account, data: key)
        return key
    }

    private static func secretAccount(for base: String) -> String { base + ".secret" }
    private static func tamperAccount(for base: String) -> String { base + ".tamper" }

    private func enterTamperCooldown(now: Date) throws {
        let until = Int(now.timeIntervalSince1970 + 900) // 15 minutes
        tamperCooldownUntilEpoch = until
        var until64 = Int64(until).littleEndian
        let data = Data(bytes: &until64, count: MemoryLayout<Int64>.size)
        try KeychainStore.write(service: config.service, account: Self.tamperAccount(for: config.account), data: data)
    }

    private func isInTamperCooldown(nowEpoch: Int) -> Bool {
        if let until = tamperCooldownUntilEpoch {
            if nowEpoch < until { return true }
            // Passed cooldown: reset state to safe empty and clear marker
            do {
                try KeychainStore.delete(service: config.service, account: Self.tamperAccount(for: config.account))
            } catch { /* ignore */ }
            tamperCooldownUntilEpoch = nil
            // Reset state
            var fresh = Self.freshWireState(now: Date(timeIntervalSince1970: TimeInterval(nowEpoch)), time: time)
            fresh.lastSeenIDFV = time.currentIDFV()
            try? persist(state: fresh)
            return false
        }
        return false
    }

    private static func freshWireState(now: Date, time: TimeProvider) -> WireState {
        let nowEpoch = Int(now.timeIntervalSince1970)
        return WireState(stamps: [],
                         lastSeenWallClock: nowEpoch,
                         lastSeenUptimeMillis: Int(time.uptimeSeconds() * 1000),
                         lastSeenIDFV: time.currentIDFV(),
                         strictModeUntil: nil)
    }

    private func effectiveMinIntervalSeconds() -> TimeInterval {
        #if !DEBUG
        if environment.shouldHarden { return config.minIntervalSeconds * 2 }
        #endif
        return config.minIntervalSeconds
    }

    private static func dayKey(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        let d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func detectEnvironment() -> EnvironmentHints {
        #if DEBUG
        return EnvironmentHints(isDebuggerOrTTYAttached: false, writableOutsideSandbox: false, hasCydia: false)
        #else
        var tty = false
        if isatty(STDIN_FILENO) != 0 || isatty(STDERR_FILENO) != 0 { tty = true }
        let fm = FileManager.default
        var writable = false
        let probe = URL(fileURLWithPath: "/private/ul_probe_\(UUID().uuidString)")
        if (try? "x".data(using: .utf8)?.write(to: probe)) != nil {
            writable = true
            try? fm.removeItem(at: probe)
        }
        let hasCydia = fm.fileExists(atPath: "/Applications/Cydia.app")
        return EnvironmentHints(isDebuggerOrTTYAttached: tty, writableOutsideSandbox: writable, hasCydia: hasCydia)
        #endif
    }
}
