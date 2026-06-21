import Foundation

struct ModelUnloadMemoryVerificationResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case recovered
        case unchanged
        case increased
        case unavailable

        var titleKey: String {
            switch self {
            case .recovered: return "Memory returned"
            case .unchanged: return "Memory unchanged"
            case .increased: return "Memory increased"
            case .unavailable: return "Memory unavailable"
            }
        }
    }

    let beforeFootprintBytes: Int64
    let afterFootprintBytes: Int64
    let releasedBytes: Int64
    let status: Status
    let checkedAt: Date

    var logSummary: String {
        "status=\(status.titleKey) before=\(beforeFootprintBytes) after=\(afterFootprintBytes) released=\(releasedBytes)"
    }
}

enum ModelUnloadVerifier {
    static let defaultRecoveryThresholdBytes: Int64 = 32 * 1024 * 1024

    static func evaluate(
        before: LiveMemoryPressureSnapshot,
        after: LiveMemoryPressureSnapshot,
        recoveryThresholdBytes: Int64 = defaultRecoveryThresholdBytes
    ) -> ModelUnloadMemoryVerificationResult {
        let beforeFootprint = before.footprintBytes
        let afterFootprint = after.footprintBytes
        guard beforeFootprint > 0, afterFootprint > 0 else {
            return ModelUnloadMemoryVerificationResult(
                beforeFootprintBytes: beforeFootprint,
                afterFootprintBytes: afterFootprint,
                releasedBytes: max(0, beforeFootprint - afterFootprint),
                status: .unavailable,
                checkedAt: after.sampledAt
            )
        }

        let released = beforeFootprint - afterFootprint
        let status: ModelUnloadMemoryVerificationResult.Status
        if released >= recoveryThresholdBytes {
            status = .recovered
        } else if released < 0 {
            status = .increased
        } else {
            status = .unchanged
        }

        return ModelUnloadMemoryVerificationResult(
            beforeFootprintBytes: beforeFootprint,
            afterFootprintBytes: afterFootprint,
            releasedBytes: max(0, released),
            status: status,
            checkedAt: after.sampledAt
        )
    }
}
