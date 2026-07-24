import AppIntents
import Foundation

// MARK: - Errors

enum NoemaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case modelNotFound
    case datasetNotFound
    case noModelAvailable
    case loadFailed(String)
    case offGridBlocked

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Noema is still starting up. Try again in a moment."
        case .modelNotFound:
            return "That model isn't installed anymore."
        case .datasetNotFound:
            return "That dataset isn't downloaded anymore."
        case .noModelAvailable:
            return "No local model is installed yet. Download one from Explore first."
        case .loadFailed(let reason):
            return "The model could not be loaded: \(reason)"
        case .offGridBlocked:
            return "Off-Grid Mode is on, so Explore and network features are unavailable."
        }
    }
}

// MARK: - Navigation

struct OpenNoemaPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page"
    static let description = IntentDescription(
        "Opens a specific page in Noema.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Page", default: .chat)
    var page: NoemaAppPage

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$page) in Noema")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        try AppIntentDriver.shared.open(page: page)
        return .result()
    }
}

struct ShowDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Downloads"
    static let description = IntentDescription(
        "Shows active and queued downloads in Noema.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        try AppIntentDriver.shared.open(page: .downloads)
        return .result()
    }
}

// MARK: - Chat

struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start New Chat"
    static let description = IntentDescription(
        "Starts a fresh chat session in Noema.",
        categoryName: "Chat"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        try AppIntentDriver.shared.startNewChat()
        return .result()
    }
}

struct AskNoemaIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Noema"
    static let description = IntentDescription(
        "Sends a question to your local AI model in a new chat. Loads your default model first if none is loaded.",
        categoryName: "Chat"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var prompt: String

    @Parameter(title: "Start New Chat", default: true)
    var newChat: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Noema \(\.$prompt)") {
            \.$newChat
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $prompt.needsValueError("What would you like to ask?")
        }
        let modelName = try await AppIntentDriver.shared.ensureModelLoaded()
        try await AppIntentDriver.shared.ask(trimmed, inNewChat: newChat)
        return .result(dialog: "Asked \(modelName). The answer is streaming in Noema.")
    }
}

// MARK: - Models

struct LoadModelIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Load Model"
    static let description = IntentDescription(
        "Loads an installed local model so it's ready to chat. Large models can take a minute on first load.",
        categoryName: "Models"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Model")
    var model: NoemaModelEntity

    @Parameter(title: "Start New Chat", default: false)
    var newChat: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Load \(\.$model) in Noema") {
            \.$newChat
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        progress.totalUnitCount = 100
        progress.completedUnitCount = 5
        // Only Sendable values may cross into the background task closure.
        let modelID = model.id
        let startNewChat = newChat

        let dialog: IntentDialog
#if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            // Model loading compiles Metal shaders and maps weights into
            // memory; tell the system it needs the GPU and may run long.
            dialog = try await performBackgroundTask(options: .requiresGPU) { @Sendable in
                try await Self.runLoad(modelID: modelID, startNewChat: startNewChat)
            }
        } else {
            dialog = try await Self.runLoad(modelID: modelID, startNewChat: startNewChat)
        }
#else
        dialog = try await Self.runLoad(modelID: modelID, startNewChat: startNewChat)
#endif
        progress.completedUnitCount = 100
        return .result(dialog: dialog)
    }

    @MainActor
    private static func runLoad(modelID: String, startNewChat: Bool) async throws -> IntentDialog {
        let loaded = try await AppIntentDriver.shared.loadModel(withID: modelID)
        if startNewChat {
            try AppIntentDriver.shared.startNewChat()
        } else {
            AppIntentDriver.shared.tabRouter?.selection = .chat
        }
        return "\(loaded.displayName) is loaded and ready to chat."
    }
}

#if NOEMA_ENABLE_XCODE27_APIS
// LongRunningIntent (iOS 27) lets the new Siri AI keep the load alive past
// the standard intent deadline instead of cancelling mid-load.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension LoadModelIntent: LongRunningIntent {}
#endif

struct UnloadModelIntent: AppIntent {
    static let title: LocalizedStringResource = "Unload Model"
    static let description = IntentDescription(
        "Ejects the currently loaded model and frees its memory.",
        categoryName: "Models"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        guard let loaded = AppIntentDriver.shared.modelManager?.loadedModel else {
            return .result(dialog: "No model is loaded right now.")
        }
        let name = loaded.displayName
        try await AppIntentDriver.shared.unloadModel()
        return .result(dialog: "Unloaded \(name).")
    }
}

struct GetLoadedModelIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Loaded Model"
    static let description = IntentDescription(
        "Tells you which local model is currently loaded in Noema.",
        categoryName: "Models"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoemaModelEntity]> & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        guard let chatVM = AppIntentDriver.shared.chatVM,
              chatVM.modelLoaded,
              let loaded = AppIntentDriver.shared.modelManager?.loadedModel,
              let model = AppIntentDriver.shared.installedModels().first(where: { $0.id == loaded.id })
        else {
            return .result(value: [], dialog: "No model is loaded right now.")
        }
        let entity = NoemaModelEntity(model: model)
        return .result(value: [entity], dialog: "\(model.displayName) is loaded.")
    }
}

struct FindInstalledModelsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Installed Models"
    static let description = IntentDescription(
        "Searches the models installed on this device by name, format or quantization.",
        categoryName: "Models"
    )

    @Parameter(title: "Search", requestValueDialog: "What kind of model are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search installed models for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoemaModelEntity]> & ProvidesDialog {
        let matches = try await NoemaModelEntityQuery().entities(matching: query)
        let dialog: IntentDialog
        switch matches.count {
        case 0:
            dialog = "No installed models match “\(query)”."
        case 1:
            dialog = "Found \(matches[0].name)."
        default:
            dialog = "Found \(matches.count) models: \(matches.prefix(5).map(\.name).joined(separator: ", "))."
        }
        return .result(value: matches, dialog: dialog)
    }
}

// MARK: - Datasets

struct UseDatasetIntent: AppIntent {
    static let title: LocalizedStringResource = "Use Dataset in Chat"
    static let description = IntentDescription(
        "Activates a downloaded dataset so chat answers are grounded in it.",
        categoryName: "Datasets"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Dataset")
    var dataset: NoemaDatasetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$dataset) in chat")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        guard let selected = try AppIntentDriver.shared.selectDataset(withID: dataset.id) else {
            throw NoemaIntentError.datasetNotFound
        }
        AppIntentDriver.shared.tabRouter?.selection = .chat
        if selected.isIndexed {
            return .result(dialog: "Chat will now use \(selected.name).")
        }
        return .result(dialog: "Selected \(selected.name), but it still needs indexing before chat can use it. Open it in Stored to index it.")
    }
}

struct StopUsingDatasetIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Using Dataset"
    static let description = IntentDescription(
        "Deactivates the current chat dataset.",
        categoryName: "Datasets"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        _ = try AppIntentDriver.shared.selectDataset(withID: nil)
        return .result(dialog: "Chat is no longer using a dataset.")
    }
}

struct OpenDatasetIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Dataset"
    static let description = IntentDescription(
        "Opens a downloaded dataset's details in Noema.",
        categoryName: "Datasets"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Dataset")
    var dataset: NoemaDatasetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$dataset) in Noema")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        try AppIntentDriver.shared.openDatasetDetail(withID: dataset.id)
        return .result()
    }
}

struct AskAboutDatasetIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask About Dataset"
    static let description = IntentDescription(
        "Activates a dataset and asks your local model a question about it.",
        categoryName: "Datasets"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Dataset")
    var dataset: NoemaDatasetEntity

    @Parameter(title: "Question", default: "Summarize the key contents of this dataset.")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask about \(\.$dataset)") {
            \.$prompt
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        guard let selected = try AppIntentDriver.shared.selectDataset(withID: dataset.id) else {
            throw NoemaIntentError.datasetNotFound
        }
        guard selected.isIndexed else {
            return .result(dialog: "\(selected.name) still needs indexing before chat can use it. Open it in Stored to index it.")
        }
        let modelName = try await AppIntentDriver.shared.ensureModelLoaded()
        try await AppIntentDriver.shared.ask(prompt, inNewChat: true)
        return .result(dialog: "Asked \(modelName) about \(selected.name). The answer is streaming in Noema.")
    }
}

// MARK: - Explore

struct SearchExploreIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Explore"
    static let description = IntentDescription(
        "Searches Explore for new models or datasets to download.",
        categoryName: "Explore"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Search", requestValueDialog: "What should I search for?")
    var query: String

    @Parameter(title: "Section", default: .models)
    var scope: NoemaExploreScope

    static var parameterSummary: some ParameterSummary {
        Summary("Search Explore for \(\.$query)") {
            \.$scope
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppIntentDriver.shared.waitUntilBound() else { throw NoemaIntentError.appNotReady }
        try AppIntentDriver.shared.searchExplore(query: query, scope: scope)
        return .result()
    }
}

// MARK: - Settings

struct SetOffGridIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Off-Grid Mode"
    static let description = IntentDescription(
        "Turns Off-Grid Mode on or off. Off-Grid Mode blocks all network access, downloads and cloud connections.",
        categoryName: "Settings"
    )

    @Parameter(title: "Mode", default: .toggle)
    var mode: NoemaOffGridMode

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off-grid mode \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let enabled = AppIntentDriver.shared.setOffGrid(mode)
        return .result(dialog: enabled
            ? "Off-Grid Mode is on. Noema is fully offline."
            : "Off-Grid Mode is off. Network features are available again.")
    }
}
