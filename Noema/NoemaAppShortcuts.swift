import AppIntents

struct NoemaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
                "Create a new offline chat in \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "plus.message"
        )
        AppShortcut(
            intent: AskNoemaIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) something",
                "Ask my local AI in \(.applicationName)"
            ],
            shortTitle: "Ask Noema",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: LoadModelIntent(),
            phrases: [
                "Load \(\.$model) in \(.applicationName)",
                "Load a model in \(.applicationName)",
                "Start \(\.$model) in \(.applicationName)"
            ],
            shortTitle: "Load Model",
            systemImageName: "cpu"
        )
        AppShortcut(
            intent: UnloadModelIntent(),
            phrases: [
                "Unload the model in \(.applicationName)",
                "Eject the model in \(.applicationName)"
            ],
            shortTitle: "Unload Model",
            systemImageName: "eject"
        )
        AppShortcut(
            intent: GetLoadedModelIntent(),
            phrases: [
                "What model is loaded in \(.applicationName)",
                "Which \(.applicationName) model is running"
            ],
            shortTitle: "Loaded Model",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: FindInstalledModelsIntent(),
            phrases: [
                "Search my \(.applicationName) models",
                "Find a model in \(.applicationName)"
            ],
            shortTitle: "Search Models",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: UseDatasetIntent(),
            phrases: [
                "Use \(\.$dataset) in \(.applicationName)",
                "Use a dataset in \(.applicationName) chat",
                "Chat with \(\.$dataset) in \(.applicationName)"
            ],
            shortTitle: "Use Dataset",
            systemImageName: "books.vertical"
        )
        AppShortcut(
            intent: SearchExploreIntent(),
            phrases: [
                "Search \(.applicationName) explore",
                "Find new models in \(.applicationName)"
            ],
            shortTitle: "Search Explore",
            systemImageName: "safari"
        )
        AppShortcut(
            intent: OpenNoemaPageIntent(),
            phrases: [
                "Open \(\.$page) in \(.applicationName)",
                "Go to \(\.$page) in \(.applicationName)",
                "Open \(.applicationName)"
            ],
            shortTitle: "Open Page",
            systemImageName: "arrow.up.forward.app"
        )
        AppShortcut(
            intent: SetOffGridIntent(),
            phrases: [
                "Toggle off-grid mode in \(.applicationName)",
                "Turn off-grid mode \(\.$mode) in \(.applicationName)",
                "Take \(.applicationName) off the grid"
            ],
            shortTitle: "Off-Grid Mode",
            systemImageName: "wifi.slash"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
