import Foundation

struct LocalRemoteRoutingAdvice: Equatable, Sendable {
    enum Route: String, Equatable, Sendable {
        case unconfigured
        case localOnly
        case remoteOnly
        case localThenRemote
        case remoteThenLocal
        case blocked
    }

    enum Detail: String, Equatable, Sendable {
        case noDefaults
        case offGridLocal
        case offGridNoLocal
        case localOnly
        case remoteOnly
        case localPriority
        case remotePriority
        case largeLocalRemoteFallback
        case lowPowerLocalEfficient
    }

    let route: Route
    let detail: Detail
}

enum LocalRemoteRoutingAdvisor {
    struct Context: Equatable, Sendable {
        var preferences: StartupPreferences
        var selectedLocalModel: LocalModelSummary?
        var remoteSelectionCount: Int
        var offGrid: Bool
        var lowPowerMode: Bool
        /// Measured Overfit verdict for the selected local model when it is a
        /// paged install with a valid canary record. nil (the default) leaves
        /// every pre-existing decision path untouched.
        var overfitClassification: OverfitFitClassification?

        init(
            preferences: StartupPreferences,
            selectedLocalModel: LocalModelSummary?,
            remoteSelectionCount: Int,
            offGrid: Bool,
            lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
            overfitClassification: OverfitFitClassification? = nil
        ) {
            self.preferences = preferences
            self.selectedLocalModel = selectedLocalModel
            self.remoteSelectionCount = remoteSelectionCount
            self.offGrid = offGrid
            self.lowPowerMode = lowPowerMode
            self.overfitClassification = overfitClassification
        }
    }

    struct LocalModelSummary: Equatable, Sendable {
        var format: ModelFormat
        var sizeGB: Double

        init(format: ModelFormat, sizeGB: Double) {
            self.format = format
            self.sizeGB = sizeGB
        }
    }

    static func advice(for context: Context) -> LocalRemoteRoutingAdvice {
        let hasLocal = context.preferences.hasLocalSelection
        let hasRemote = context.remoteSelectionCount > 0 && context.preferences.hasRemoteSelection

        guard hasLocal || hasRemote else {
            return LocalRemoteRoutingAdvice(route: .unconfigured, detail: .noDefaults)
        }

        if context.offGrid {
            if hasLocal {
                return LocalRemoteRoutingAdvice(route: .localOnly, detail: .offGridLocal)
            }
            return LocalRemoteRoutingAdvice(route: .blocked, detail: .offGridNoLocal)
        }

        if hasLocal, !hasRemote {
            return LocalRemoteRoutingAdvice(route: .localOnly, detail: .localOnly)
        }

        if !hasLocal, hasRemote {
            return LocalRemoteRoutingAdvice(route: .remoteOnly, detail: .remoteOnly)
        }

        // Both routes are configured and we are on-grid. A measured Overfit
        // verdict outranks the heuristics below: it reflects how the paged
        // model actually ran on this device. Details reuse existing cases
        // because SettingsView switches over Detail exhaustively.
        if let classification = context.overfitClassification {
            switch classification {
            case .relayRecommended, .offlineOnly:
                return LocalRemoteRoutingAdvice(route: .remoteThenLocal, detail: .remotePriority)
            case .pagedSlow:
                return LocalRemoteRoutingAdvice(route: .localThenRemote, detail: .largeLocalRemoteFallback)
            case .residentInteractive, .pagedInteractive, .unsupported:
                break
            }
        }

        if context.lowPowerMode, let model = context.selectedLocalModel, model.isBatteryEfficient {
            return LocalRemoteRoutingAdvice(route: .localThenRemote, detail: .lowPowerLocalEfficient)
        }

        if let model = context.selectedLocalModel, model.isLargeGGUF {
            switch context.preferences.priority {
            case .localFirst:
                return LocalRemoteRoutingAdvice(route: .localThenRemote, detail: .largeLocalRemoteFallback)
            case .remoteFirst:
                return LocalRemoteRoutingAdvice(route: .remoteThenLocal, detail: .remotePriority)
            }
        }

        switch context.preferences.priority {
        case .localFirst:
            return LocalRemoteRoutingAdvice(route: .localThenRemote, detail: .localPriority)
        case .remoteFirst:
            return LocalRemoteRoutingAdvice(route: .remoteThenLocal, detail: .remotePriority)
        }
    }
}

extension LocalRemoteRoutingAdvisor.LocalModelSummary {
    init(model: LocalModel) {
        self.init(format: model.format, sizeGB: model.sizeGB)
    }

    var isLargeGGUF: Bool {
        format == .gguf && sizeGB >= 6
    }

    var isBatteryEfficient: Bool {
        switch format {
        case .et, .ane, .afm, .coreai:
            return true
        case .gguf, .mlx:
            return sizeGB <= 3
        }
    }
}
