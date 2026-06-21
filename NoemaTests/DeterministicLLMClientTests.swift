import Foundation
import XCTest
@testable import Noema

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

final class DeterministicLLMClientTests: XCTestCase {
    func testFakeClientAggregatesTextAndCapturesInput() async throws {
        let probe = DeterministicLLMClientProbe()
        let client = AnyLLMClient.makeDeterministicFake(
            chunks: ["Hello", ", ", "Noema"],
            probe: probe
        )

        let output = try await client.text(from: .plain("test prompt"))
        let tokenCount = await client.countTokens(in: "one two three")

        XCTAssertEqual(output, "Hello, Noema")
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(probe.inputs.first?.prompt, "test prompt")
        XCTAssertEqual(tokenCount, 3)
    }

    func testFakeClientReportsPromptProgressForStreamingPath() async throws {
        let progress = LockedValues<Double>()
        let probe = DeterministicLLMClientProbe()
        let client = AnyLLMClient.makeDeterministicFake(
            chunks: ["A", "B"],
            probe: probe
        )

        let stream = try await client.textStream(from: .plain("stream prompt")) { value in
            progress.append(value)
        }
        var output = ""
        for try await chunk in stream {
            output += chunk
        }

        XCTAssertEqual(output, "AB")
        XCTAssertEqual(progress.snapshot(), [0, 1])
        XCTAssertEqual(probe.inputs.map(\.prompt), ["stream prompt"])
    }

    func testFakeClientCancellationAndLifecycleHooksAreDeterministic() async throws {
        let probe = DeterministicLLMClientProbe()
        let client = AnyLLMClient.makeDeterministicFake(
            chunks: ["first", "second", "third"],
            delayNanoseconds: 20_000_000,
            probe: probe
        )
        let stream = try await client.textStream(from: .plain("cancel prompt"))
        var iterator = stream.makeAsyncIterator()

        let first = try await iterator.next()
        client.cancelActive()

        XCTAssertEqual(first, "first")
        do {
            _ = try await iterator.next()
            XCTFail("Expected cancellation after cancelActive()")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(probe.isCancelled)
        await client.reset()
        XCTAssertFalse(probe.isCancelled)
        XCTAssertEqual(probe.resetCount, 1)

        client.unload()
        await client.unloadAndWait()
        XCTAssertEqual(probe.unloadCount, 1)
        XCTAssertEqual(probe.asyncUnloadCount, 1)
    }
}
