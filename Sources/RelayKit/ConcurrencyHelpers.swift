import Foundation

// Simple async semaphore to bound concurrent background work.
actor AsyncSemaphore {
    private var value: Int
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(value: Int) {
        self.value = max(1, value)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if value > 0 {
            value -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            value += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// Tracks identifiers currently being processed to avoid duplicate work
// when multiple polls overlap.
actor InFlightTracker<Key: Hashable> {
    private var set: Set<Key> = []

    func tryInsert(_ key: Key) -> Bool {
        if set.contains(key) { return false }
        set.insert(key)
        return true
    }

    func remove(_ key: Key) {
        set.remove(key)
    }
}
