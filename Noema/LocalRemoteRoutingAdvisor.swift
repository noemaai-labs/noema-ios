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

        init(
            preferences: StartupPreferences,
            selectedLocalModel: LocalModelSummary?,
            remoteSelectionCount: Int,
            offGrid: Bool,
            lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
        ) {
            self.preferences = preferences
            self.selectedLocalModel = selectedLocalModel
            self.remoteSelectionCount = remoteSelectionCount
            self.offGrid = offGrid
            self.lowPowerMode = lowPowerMode
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
