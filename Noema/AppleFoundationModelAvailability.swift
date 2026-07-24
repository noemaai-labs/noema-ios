import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleFoundationModelUnavailableReason: Equatable, Sendable {
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedDevice

    var message: String {
        switch self {
        case .appleIntelligenceNotEnabled:
            return String(localized: "Apple Intelligence is turned off. Enable Apple Intelligence to use AFM.")
        case .modelNotReady:
            return String(localized: "Apple Foundation Model is not ready yet. Try again in a moment.")
        case .unsupportedDevice:
            return String(localized: "Apple Foundation Models are not supported on this device.")
        }
    }
}

struct AppleFoundationModelAvailabilityState: Equatable, Sendable {
    let isSupportedDevice: Bool
    let isAvailableNow: Bool
    let unavailableReason: AppleFoundationModelUnavailableReason?
}

enum AppleFoundationModelAvailability {
    static var current: AppleFoundationModelAvailabilityState {
        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return AppleFoundationModelAvailabilityState(
                    isSupportedDevice: true,
                    isAvailableNow: true,
                    unavailableReason: nil
                )
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return AppleFoundationModelAvailabilityState(
                        isSupportedDevice: true,
                        isAvailableNow: false,
                        unavailableReason: .appleIntelligenceNotEnabled
                    )
                case .modelNotReady:
                    return AppleFoundationModelAvailabilityState(
                        isSupportedDevice: true,
                        isAvailableNow: false,
                        unavailableReason: .modelNotReady
                    )
                case .deviceNotEligible:
                    return AppleFoundationModelAvailabilityState(
                        isSupportedDevice: false,
                        isAvailableNow: false,
                        unavailableReason: .unsupportedDevice
                    )
                @unknown default:
                    return AppleFoundationModelAvailabilityState(
                        isSupportedDevice: false,
                        isAvailableNow: false,
                        unavailableReason: .unsupportedDevice
                    )
                }
            @unknown default:
                return AppleFoundationModelAvailabilityState(
                    isSupportedDevice: false,
                    isAvailableNow: false,
                    unavailableReason: .unsupportedDevice
                )
            }
        }
        #endif
        #endif

        return AppleFoundationModelAvailabilityState(
            isSupportedDevice: false,
            isAvailableNow: false,
            unavailableReason: .unsupportedDevice
        )
    }

    static var isSupportedDevice: Bool { current.isSupportedDevice }
    static var isAvailableNow: Bool { current.isAvailableNow }
    static var unavailableReason: AppleFoundationModelUnavailableReason? { current.unavailableReason }
}

enum ApplePrivateCloudComputeAvailabilityStatus: Equatable, Sendable {
    case available
    case approachingLimit
    case limitReached(resetDate: Date?)
    case unavailable(message: String)

    var isAvailableForRequests: Bool {
        switch self {
        case .available, .approachingLimit:
            return true
        case .limitReached, .unavailable:
            return false
        }
    }

    var message: String {
        switch self {
        case .available:
            return String(localized: "Available")
        case .approachingLimit:
            return String(localized: "Nearing daily usage limit")
        case .limitReached(let resetDate):
            if let resetDate {
                return String.localizedStringWithFormat(
                    String(localized: "Daily usage limit reached. Available again %@."),
                    resetDate.formatted(date: .abbreviated, time: .shortened)
                )
            }
            return String(localized: "Daily usage limit reached")
        case .unavailable(let message):
            return message
        }
    }
}

enum ApplePrivateCloudComputeAvailability {
    static var isRuntimeSupported: Bool {
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    static var isSelectable: Bool {
        isRuntimeSupported && AppleFoundationModelAvailability.isSupportedDevice
    }

    static var status: ApplePrivateCloudComputeAvailabilityStatus {
        guard isRuntimeSupported else {
            return .unavailable(message: String(localized: "Apple Private Cloud Compute requires iOS, iPadOS, macOS, or visionOS 27."))
        }
        guard !UserDefaults.standard.bool(forKey: "offGrid"),
              !EnterprisePolicyGate.requiresOffGrid else {
            return .unavailable(message: String(localized: "Private Cloud Compute is unavailable while Off-Grid mode is on."))
        }
        guard !NetworkKillSwitch.isEnabled else {
            return .unavailable(message: String(localized: "Private Cloud Compute is unavailable while network access is disabled."))
        }
        guard EnterprisePolicyGate.remoteInferenceAllowed else {
            return .unavailable(message: String(localized: "Blocked by your organization's policy."))
        }
        guard NetworkReachability.shared.isOnline else {
            return .unavailable(message: String(localized: "Private Cloud Compute requires an internet connection."))
        }

        #if canImport(FoundationModels)
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                let quota = model.quotaUsage
                if quota.isLimitReached {
                    return .limitReached(resetDate: quota.resetDate)
                }
                if case .belowLimit(let information) = quota.status,
                   information.isApproachingLimit {
                    return .approachingLimit
                }
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(message: String(localized: "Private Cloud Compute is not available on this device."))
            case .unavailable(.systemNotReady):
                return .unavailable(message: String(localized: "Private Cloud Compute is not ready yet. Try again in a moment."))
            case .unavailable:
                return .unavailable(message: String(localized: "Private Cloud Compute is currently unavailable."))
            @unknown default:
                return .unavailable(message: String(localized: "Private Cloud Compute is currently unavailable."))
            }
        }
        #endif
        #endif

        return .unavailable(message: String(localized: "Private Cloud Compute is unavailable in this build."))
    }

    static var isAvailableNow: Bool {
        status.isAvailableForRequests
    }

    static var canShowQuotaOptions: Bool {
        #if canImport(FoundationModels)
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion != nil
        }
        #endif
        #endif
        return false
    }

    static func showQuotaOptions() {
        #if canImport(FoundationModels)
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
           let suggestion = PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion {
            suggestion.show()
        }
        #endif
        #endif
    }
}
