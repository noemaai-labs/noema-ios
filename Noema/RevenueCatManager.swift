import Foundation

@MainActor
final class RevenueCatManager: ObservableObject {
    static let shared = RevenueCatManager()

    private init() {}

    static func configure() {
        // No-op: web search is free and no subscription system is required.
    }

    func refreshEntitlements() async {
        // No-op: entitlements are no longer tracked.
    }
}
