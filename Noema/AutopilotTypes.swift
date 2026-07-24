import Foundation

// Autopilot: per-message local↔cloud routing. Pure types shared by the gates,
// the LLM router brain, the heuristic fallback, and the chat pipeline —
// deliberately free of UI imports so they compile and unit-test everywhere.

enum AutoRouteTarget: String, Codable, Sendable, Equatable {
    case local
    case cloud
}

/// Which mechanism decides when the stronger model steps in.
/// - `router`: a small cloud router reads every message before generation and
///   picks local vs escalation (the original Autopilot).
/// - `phoneAFriend`: no pre-turn router; the local model itself calls the
///   `noema.assist.handoff` tool mid-answer when a request is beyond it, and
///   the escalation model takes over the turn.
enum AutopilotSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case router
    case phoneAFriend = "phone_a_friend"

    var id: String { rawValue }
}

/// Which model supplies Smart Router's semantic verdict.
enum RouterBrainKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// An OpenAI-compatible endpoint selected by the user.
    case remote
    /// Apple's on-device Foundation Model. Only an escalated answer may leave
    /// the device; routing itself never uses the network.
    case appleFoundationModel
    /// Apple's privacy-preserving server model supplies the routing verdict.
    case privateCloudCompute

    var id: String { rawValue }
}

/// Where escalated turns run.
enum AutopilotEscalationTarget: String, Codable, Sendable {
    case remote
    /// A second, stronger local model kept resident next to the chat model.
    /// macOS only — it needs the RAM headroom to dual-load.
    case localModel = "local_model"
    /// Apple's privacy-preserving server model answers escalated turns.
    case privateCloudCompute = "private_cloud_compute"
}

/// A stronger installed local model chosen as the escalation target (macOS).
/// Resolved against `AppModelManager.downloadedModels` by `modelID` + `quant`,
/// falling back to the stored path, so the reference survives re-downloads.
struct AutopilotLocalEscalationSelection: Codable, Equatable, Sendable {
    var modelID: String
    var name: String
    var quant: String
    var format: ModelFormat
    var urlPath: String
    var contextLength: Int
}

enum RouterAggressiveness: String, Codable, CaseIterable, Identifiable, Sendable {
    case conserve
    case balanced
    case frontier

    var id: String { rawValue }

    /// Minimum LLM confidence required before a cloud verdict is acted on.
    var cloudConfidenceGate: Double {
        switch self {
        case .conserve: return 0.75
        case .balanced: return 0.60
        case .frontier: return 0.50
        }
    }

    /// Additive-score threshold used by `AutopilotHeuristic`.
    var heuristicThreshold: Int {
        switch self {
        case .conserve: return 6
        case .balanced: return 4
        case .frontier: return 3
        }
    }
}

struct AutoRouteDecision: Equatable, Sendable {
    enum DecidedBy: String, Codable, Sendable {
        case forced
        case llm
        /// Apple's on-device Foundation Model supplied the semantic verdict.
        case afm
        /// Apple Private Cloud Compute supplied the semantic verdict.
        case pcc
        case heuristic
        /// Phone-a-friend: the local model itself asked for the handoff.
        case phoneAFriend = "phone_a_friend"
    }

    enum Category: String, Codable, Sendable, CaseIterable {
        case casualChat = "casual_chat"
        case factual
        case writing
        case summarization
        case formatting
        case translation
        case codingLight = "coding_light"
        case codingHeavy = "coding_heavy"
        case mathReasoning = "math_reasoning"
        case longContext = "long_context"
        case obscureKnowledge = "obscure_knowledge"
        case highStakes = "high_stakes"
        case multiStep = "multi_step"
        /// The user explicitly asked for the cloud/strongest model.
        case explicitRequest = "explicit_request"
        case other
    }

    var target: AutoRouteTarget
    var confidence: Double
    /// LLM verdicts carry a free-text sentence; gate/heuristic verdicts carry a
    /// localization key in `reasonKey` and leave this as the resolved English.
    var reason: String
    var reasonKey: String?
    var category: Category?
    var estDifficulty: Int
    var latencyMs: Int
    var decidedBy: DecidedBy

    static func forced(_ target: AutoRouteTarget, reasonKey: String, confidence: Double = 1.0) -> AutoRouteDecision {
        AutoRouteDecision(
            target: target,
            confidence: confidence,
            reason: reasonKey,
            reasonKey: reasonKey,
            category: nil,
            estDifficulty: 1,
            latencyMs: 0,
            decidedBy: .forced
        )
    }
}

/// Persisted onto `Msg` for the ESCALATION row, badges, ledger, and diagnostics.
struct RouteDecisionRecord: Equatable, Codable, Sendable {
    var target: AutoRouteTarget
    var decidedBy: AutoRouteDecision.DecidedBy
    var confidence: Double
    var reason: String
    var reasonKey: String?
    var category: String?
    var estDifficulty: Int?
    var routerLatencyMs: Int
    var escalationBackendName: String?
    var escalationModelName: String?
    var fellBackToLocal: Bool
    var failedMidStream: Bool
    /// User explicitly re-routed this answer ("Redo On-Device"/"Redo on Cloud").
    var userOverride: Bool
    /// The escalation target was a second local model, not a cloud backend.
    /// Optional so records persisted before this field existed still decode.
    var escalationIsLocal: Bool?
    /// The escalation target was Apple Private Cloud Compute.
    var escalationUsesPrivateCloudCompute: Bool?

    /// Where the visible answer actually ran. `target` remains the router's
    /// original decision so a pre-token cloud failure does not rewrite AFM's
    /// verdict after the fact.
    var answerTarget: AutoRouteTarget {
        fellBackToLocal ? .local : target
    }

    init(decision: AutoRouteDecision,
         escalationBackendName: String? = nil,
         escalationModelName: String? = nil,
         fellBackToLocal: Bool = false,
         failedMidStream: Bool = false,
         userOverride: Bool = false,
         escalationIsLocal: Bool = false,
         escalationUsesPrivateCloudCompute: Bool = false) {
        self.target = decision.target
        self.decidedBy = decision.decidedBy
        self.confidence = decision.confidence
        self.reason = decision.reason
        self.reasonKey = decision.reasonKey
        self.category = decision.category?.rawValue
        self.estDifficulty = decision.estDifficulty
        self.routerLatencyMs = decision.latencyMs
        self.escalationBackendName = escalationBackendName
        self.escalationModelName = escalationModelName
        self.fellBackToLocal = fellBackToLocal
        self.failedMidStream = failedMidStream
        self.userOverride = userOverride
        self.escalationIsLocal = escalationIsLocal ? true : nil
        self.escalationUsesPrivateCloudCompute = escalationUsesPrivateCloudCompute ? true : nil
    }
}

struct LocalModelCard: Sendable, Equatable {
    var name: String
    var format: ModelFormat
    var sizeGB: Double
    var quant: String
    var parameterLabel: String
    var contextLength: Int
    var isToolCapable: Bool
    var isMultimodal: Bool
    var moeSummary: String?
    var recentAvgTokPerSec: Double?
}

struct EscalationModelCard: Sendable, Equatable {
    var name: String
    var contextLength: Int?
    var promptPricePerMillion: Double?
    var completionPricePerMillion: Double?
    /// Whether the escalation target accepts image input; image turns are
    /// forced local when it doesn't.
    var isVisionCapable: Bool = false
}

struct AutoRouteInputs: Sendable {
    var userMessage: String
    var previousUserMessage: String?
    var conversationTurnCount: Int
    var historyTokenEstimate: Int
    var priorLocalRoutes: Int
    var priorCloudRoutes: Int
    /// Route that produced the most recent answer (cloud fallbacks count as local).
    var lastRoute: AutoRouteTarget? = nil
    var localModel: LocalModelCard
    var escalationModel: EscalationModelCard
    var hasImages: Bool
    var imageCount: Int
    var documentCount: Int
    var ragArmed: Bool
    var webSearchArmed: Bool
    var pythonArmed: Bool
    var promptTokenEstimate: Int?
    var batteryLevel: Float
    var isCharging: Bool
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState
    /// Active-document capabilities for the same turn. Defaults to no document
    /// so older call sites and deterministic router tests remain source-compatible.
    var documentAccess: DocumentAccessContext = .none
}

struct AutopilotConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var system: AutopilotSystem
    var routerKind: RouterBrainKind
    var routerSelection: StartupPreferences.RemoteSelection?
    var escalationSelection: StartupPreferences.RemoteSelection?
    var escalationTarget: AutopilotEscalationTarget
    /// Non-nil only when `escalationTarget == .localModel` (macOS).
    var localEscalation: AutopilotLocalEscalationSelection?
    var aggressiveness: RouterAggressiveness
    var allowCloudForRAGTurns: Bool
    /// Router still runs and records verdicts, but every answer stays local.
    var pauseCloudEscalation: Bool
    var consentAcceptedAt: Date?
    /// Host the consent was granted for; a changed router host re-prompts.
    var consentedRouterHost: String?

    static let storageKey = "autopilot.config.v1"

    init(enabled: Bool = false,
         system: AutopilotSystem = .router,
         routerKind: RouterBrainKind = .remote,
         routerSelection: StartupPreferences.RemoteSelection? = nil,
         escalationSelection: StartupPreferences.RemoteSelection? = nil,
         escalationTarget: AutopilotEscalationTarget = .remote,
         localEscalation: AutopilotLocalEscalationSelection? = nil,
         aggressiveness: RouterAggressiveness = .balanced,
         allowCloudForRAGTurns: Bool = false,
         pauseCloudEscalation: Bool = false,
         consentAcceptedAt: Date? = nil,
         consentedRouterHost: String? = nil) {
        self.enabled = enabled
        self.system = system
        self.routerKind = routerKind
        self.routerSelection = routerSelection
        self.escalationSelection = escalationSelection
        self.escalationTarget = escalationTarget
        self.localEscalation = localEscalation
        self.aggressiveness = aggressiveness
        self.allowCloudForRAGTurns = allowCloudForRAGTurns
        self.pauseCloudEscalation = pauseCloudEscalation
        self.consentAcceptedAt = consentAcceptedAt
        self.consentedRouterHost = consentedRouterHost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        system = (try? c.decode(AutopilotSystem.self, forKey: .system)) ?? .router
        routerKind = (try? c.decode(RouterBrainKind.self, forKey: .routerKind)) ?? .remote
        routerSelection = try? c.decodeIfPresent(StartupPreferences.RemoteSelection.self, forKey: .routerSelection)
        escalationSelection = try? c.decodeIfPresent(StartupPreferences.RemoteSelection.self, forKey: .escalationSelection)
        escalationTarget = (try? c.decode(AutopilotEscalationTarget.self, forKey: .escalationTarget)) ?? .remote
        localEscalation = try? c.decodeIfPresent(AutopilotLocalEscalationSelection.self, forKey: .localEscalation)
        aggressiveness = (try? c.decode(RouterAggressiveness.self, forKey: .aggressiveness)) ?? .balanced
        allowCloudForRAGTurns = (try? c.decode(Bool.self, forKey: .allowCloudForRAGTurns)) ?? false
        pauseCloudEscalation = (try? c.decode(Bool.self, forKey: .pauseCloudEscalation)) ?? false
        consentAcceptedAt = try? c.decodeIfPresent(Date.self, forKey: .consentAcceptedAt)
        consentedRouterHost = try? c.decodeIfPresent(String.self, forKey: .consentedRouterHost)
    }

    var escalationConfigured: Bool {
        switch escalationTarget {
        case .remote: return escalationSelection != nil
        case .localModel: return localEscalation != nil
        case .privateCloudCompute: return ApplePrivateCloudComputeAvailability.isSelectable
        }
    }

    var isConfigured: Bool {
        switch system {
        case .router:
            let routerConfigured = routerKind != .remote || routerSelection != nil
            return routerConfigured && escalationConfigured
        case .phoneAFriend:
            // No pre-turn router; the local model decides via tool call.
            return escalationConfigured
        }
    }

    var hasConsent: Bool {
        consentAcceptedAt != nil
    }

    /// Whether any part of this configuration sends conversation content to a
    /// cloud endpoint. AFM routing or phone-a-friend paired with local
    /// escalation is fully on-device and needs no cloud consent.
    var requiresCloudConsent: Bool {
        switch system {
        case .router:
            return routerKind == .remote
                || routerKind == .privateCloudCompute
                || escalationTarget != .localModel
        case .phoneAFriend: return escalationTarget != .localModel
        }
    }

    var isReadyToArm: Bool {
        isConfigured && (!requiresCloudConsent || hasConsent)
    }

    /// Display name of whichever stronger model escalations run on.
    var escalationDisplayName: String? {
        switch escalationTarget {
        case .remote: return escalationSelection?.modelName
        case .localModel: return localEscalation?.name
        case .privateCloudCompute: return AppleFoundationModelKind.privateCloudCompute.modelName
        }
    }
}

enum AutopilotConfigStore {
    static func load(defaults: UserDefaults = .standard) -> AutopilotConfig {
        guard let data = defaults.data(forKey: AutopilotConfig.storageKey),
              let decoded = try? JSONDecoder().decode(AutopilotConfig.self, from: data) else {
            return AutopilotConfig()
        }
        return decoded
    }

    static func save(_ config: AutopilotConfig, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: AutopilotConfig.storageKey)
    }
}

/// Reason keys for gate/heuristic verdicts. Every key here must have a matching
/// entry in Localizable.strings; the LLM path never uses these.
enum AutopilotReasonKey {
    static let offGrid = "router.reason.offGrid"
    static let enterprise = "router.reason.enterprise"
    static let killSwitch = "router.reason.killSwitch"
    static let noEscalationTarget = "router.reason.noEscalationTarget"
    static let escalationPaused = "router.reason.escalationPaused"
    static let imagesLocalOnly = "router.reason.imagesLocalOnly"
    static let ragPrivacy = "router.reason.ragPrivacy"
    static let contextOverflow = "router.reason.contextOverflow"
    static let simpleLocal = "router.reason.simpleLocal"
    static let localCapable = "router.reason.localCapable"
    static let cloudCapable = "router.reason.cloudCapable"
    static let longRequest = "router.reason.longRequest"
    static let heavyCode = "router.reason.heavyCode"
    static let hardMath = "router.reason.hardMath"
    static let highStakes = "router.reason.highStakes"
    static let deviceHot = "router.reason.deviceHot"
    static let routerTimeout = "router.reason.fallbackTimeout"
    static let routerUnreachable = "router.reason.fallbackUnreachable"
    static let routerUnparseable = "router.reason.fallbackUnparseable"
    static let routerKeyRejected = "router.reason.fallbackKeyRejected"
    static let routerProviderError = "router.reason.fallbackProviderError"
    static let userOverride = "router.reason.userOverride"
    static let cloudFailed = "router.reason.cloudFailed"
    static let lowRouterConfidence = "router.reason.lowRouterConfidence"
    static let routineForMode = "router.reason.routineForMode"
    static let routerCoolingDown = "router.reason.coolingDown"
    static let phoneAFriend = "router.reason.phoneAFriend"
    static let phoneAFriendUnavailable = "router.reason.phoneAFriendUnavailable"

    static func localized(_ key: String) -> String {
        switch key {
        case offGrid: return String(localized: "You're offline or Off-Grid, so nothing was sent. This answer ran on-device.")
        case enterprise: return String(localized: "Your organization's policy keeps answers on-device.")
        case killSwitch: return String(localized: "Network access is disabled, so this answer ran on-device.")
        case noEscalationTarget: return String(localized: "No cloud model is configured, so this answer ran on-device.")
        case escalationPaused: return String(localized: "Cloud escalation is paused, so this answer ran on-device.")
        case imagesLocalOnly: return String(localized: "Messages with images stay on-device.")
        case ragPrivacy: return String(localized: "Knowledge-base chats stay on-device.")
        case contextOverflow: return String(localized: "This conversation exceeds the local context window.")
        case simpleLocal: return String(localized: "A simple request the local model handles well.")
        case localCapable: return String(localized: "The local model can handle this request.")
        case cloudCapable: return String(localized: "This request benefits from the cloud model.")
        case longRequest: return String(localized: "A long, multi-part request that benefits from the cloud model.")
        case heavyCode: return String(localized: "Heavy code work that benefits from the cloud model.")
        case hardMath: return String(localized: "Formal reasoning that benefits from the cloud model.")
        case highStakes: return String(localized: "High-stakes details deserve the stronger model.")
        case deviceHot: return String(localized: "The device is under thermal pressure, so the cloud model answered.")
        case routerTimeout: return String(localized: "The router was slow to respond, so a quick local check decided.")
        case routerUnreachable: return String(localized: "The router was unreachable, so a quick local check decided.")
        case routerUnparseable: return String(localized: "The router's reply was unreadable, so a quick local check decided.")
        case routerKeyRejected: return String(localized: "The router refused the request — check your key and credits. A quick local check decided.")
        case routerProviderError: return String(localized: "The router model's provider had an outage, so a quick local check decided. A different router model may be more reliable.")
        case userOverride: return String(localized: "You chose where this answer ran.")
        case cloudFailed: return String(localized: "Cloud didn't answer, so this reply ran on-device.")
        case lowRouterConfidence: return String(localized: "The router wasn't sure the cloud was needed, so this answer ran on-device.")
        case routineForMode: return String(localized: "Routine difficulty for your Autopilot setting, so the local model answered.")
        case routerCoolingDown: return String(localized: "The router failed repeatedly just now, so a quick local check decides for a few minutes.")
        case phoneAFriend: return String(localized: "The on-device model asked the stronger model to take over.")
        case phoneAFriendUnavailable: return String(localized: "The stronger model wasn't available, so this answer ran on-device.")
        default: return key
        }
    }
}
