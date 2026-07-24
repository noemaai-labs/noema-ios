import Foundation
import XCTest
@testable import Noema

final class NetworkKillSwitchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NetworkKillSwitch.setEnabled(false)
    }

    override func tearDown() {
        NetworkKillSwitch.setEnabled(false)
        super.tearDown()
    }

    func testShouldBlockAllowsTrueLoopbackHosts() throws {
        NetworkKillSwitch.setEnabled(true)

        let allowedURLs = [
            try XCTUnwrap(URL(string: "http://127.0.0.1:8080")),
            try XCTUnwrap(URL(string: "http://localhost:8080")),
            try XCTUnwrap(URL(string: "http://[::1]:8080")),
            try XCTUnwrap(URL(string: "http://[::ffff:127.0.0.1]:8080"))
        ]

        for url in allowedURLs {
            XCTAssertFalse(NetworkKillSwitch.shouldBlock(url: url), "Expected loopback host to stay reachable: \(url)")
        }
    }

    func testShouldBlockRejectsExternalAndLANHosts() throws {
        NetworkKillSwitch.setEnabled(true)

        let blockedURLs = [
            try XCTUnwrap(URL(string: "https://huggingface.co")),
            try XCTUnwrap(URL(string: "http://192.168.1.10")),
            try XCTUnwrap(URL(string: "http://my-host.local"))
        ]

        for url in blockedURLs {
            XCTAssertTrue(NetworkKillSwitch.shouldBlock(url: url), "Expected off-grid to block host: \(url)")
        }
    }

    func testURLProtocolSkipsLoopbackRequests() throws {
        NetworkKillSwitch.setEnabled(true)

        let loopback = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080")))
        let external = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com")))

        XCTAssertFalse(NetworkBlockedURLProtocol.canInit(with: loopback))
        XCTAssertTrue(NetworkBlockedURLProtocol.canInit(with: external))
    }

    func testEnablingOffGridDoesNotCancelUntrackedLoopbackSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedLoopbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/health")))
        let task = Task {
            try await session.data(for: request)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        NetworkKillSwitch.setEnabled(true)

        let (data, response) = try await task.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true}")
    }

    func testTrackedSessionRemainsReusableAfterOffGridCancelsItsTask() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedExternalURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        NetworkKillSwitch.track(session: session)
        let url = try XCTUnwrap(URL(string: "https://example.com/resource"))

        let first = Task { try await session.data(from: url) }
        try await Task.sleep(nanoseconds: 50_000_000)
        NetworkKillSwitch.setEnabled(true)

        do {
            _ = try await first.value
            XCTFail("Expected the in-flight external request to be cancelled")
        } catch {
            // Expected: enabling off-grid cancels the blocked task.
        }

        NetworkKillSwitch.setEnabled(false)
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
    }
}

private final class DelayedLoopbackURLProtocol: URLProtocol {
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        responseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let client else { return }
            let response = HTTPURLResponse(
                url: self.request.url ?? URL(string: "http://127.0.0.1")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private final class DelayedExternalURLProtocol: URLProtocol {
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        responseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let client, let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain"]
                  ) else { return }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data("ok".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}
