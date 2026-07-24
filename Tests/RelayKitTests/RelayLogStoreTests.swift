import XCTest
@testable import RelayKit

final class RelayLogStoreTests: XCTestCase {
    @MainActor
    func testPausingCancelsPendingFlushUntilResumed() async throws {
        let store = RelayLogStore.shared
        store.clear()
        store.append(RelayLogEntry(category: "test", message: "pending"))
        store.setPaused(true)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.entries.isEmpty)

        store.setPaused(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.entries.map(\.message), ["pending"])
        store.clear()
    }
}
