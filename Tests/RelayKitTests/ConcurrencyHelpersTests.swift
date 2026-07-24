import XCTest
@testable import RelayKit

final class ConcurrencyHelpersTests: XCTestCase {
    func testCancelledSemaphoreWaiterDoesNotConsumeNextPermit() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.acquire()

        let waiter = Task {
            try await semaphore.acquire()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Expected the waiting acquisition to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        await semaphore.release()
        try await semaphore.acquire()
        await semaphore.release()
    }
}
