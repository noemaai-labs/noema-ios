import SwiftUI

@MainActor
enum MainTab: Hashable {
    case chat
    case stored
    case explore
#if os(macOS)
    case relay
#endif
    case tools
    case settings
}

@MainActor
final class TabRouter: ObservableObject {
    @Published var selection: MainTab = .chat
    @Published var pendingStoredDatasetID: String?
    // Explore navigation requested from outside the view hierarchy
    // (Siri / App Intents): the container applies the section, the matching
    // explore view consumes the search query.
    @Published var pendingExploreSection: ExploreSection?
    @Published var pendingExploreSearch: String?
    @Published var isAFMHiddenNoticeVisible = false

    /// Hands the pending Explore query to the view that owns `section`,
    /// clearing it so it only runs once.
    func consumePendingExploreSearch(for section: ExploreSection) -> String? {
        guard let query = pendingExploreSearch else { return nil }
        if let target = pendingExploreSection, target != section { return nil }
        pendingExploreSearch = nil
        pendingExploreSection = nil
        return query
    }

    private var afmHiddenNoticeTask: Task<Void, Never>?

    func showAFMHiddenNotice(duration: TimeInterval = 3) {
        afmHiddenNoticeTask?.cancel()
        isAFMHiddenNoticeVisible = true
        afmHiddenNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.isAFMHiddenNoticeVisible = false
            self?.afmHiddenNoticeTask = nil
        }
    }

    func dismissAFMHiddenNotice() {
        afmHiddenNoticeTask?.cancel()
        afmHiddenNoticeTask = nil
        isAFMHiddenNoticeVisible = false
    }
}
