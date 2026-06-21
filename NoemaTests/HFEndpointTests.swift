import Foundation
import XCTest
@testable import Noema

final class HFEndpointTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        HFEndpoint.applyEnvironment()
        super.tearDown()
    }

    private func clearKeys() {
        defaults.removeObject(forKey: HFEndpoint.modeKey)
        defaults.removeObject(forKey: HFEndpoint.customURLKey)
    }

    private func setMode(_ mode: HFEndpoint.Mode, customURL: String? = nil) {
        defaults.set(mode.rawValue, forKey: HFEndpoint.modeKey)
        if let customURL { defaults.set(customURL, forKey: HFEndpoint.customURLKey) }
    }

    // MARK: - Official mode (default)

    func testOfficialModeIsDefaultAndDoesNotRewrite() {
        XCTAssertEqual(HFEndpoint.mode, .official)
        XCTAssertNil(HFEndpoint.baseURL)
        XCTAssertEqual(HFEndpoint.webBaseString, "https://huggingface.co")
        let url = URL(string: "https://huggingface.co/api/models?search=qwen&limit=20")!
        XCTAssertEqual(HFEndpoint.rewrite(url), url)
    }

    // MARK: - Mirror mode rewriting

    func testMirrorRewritePreservesPathAndQuery() {
        setMode(.mirror)
        let search = URL(string: "https://huggingface.co/api/models?search=qwen&limit=20&full=true")!
        XCTAssertEqual(HFEndpoint.rewrite(search).absoluteString,
                       "https://hf-mirror.com/api/models?search=qwen&limit=20&full=true")

        let resolve = URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q3_K_M.gguf?download=1")!
        XCTAssertEqual(HFEndpoint.rewrite(resolve).absoluteString,
                       "https://hf-mirror.com/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q3_K_M.gguf?download=1")

        let datasets = URL(string: "https://huggingface.co/datasets/foo/bar/resolve/main/data.json?download=1")!
        XCTAssertEqual(HFEndpoint.rewrite(datasets).host, "hf-mirror.com")
        XCTAssertEqual(HFEndpoint.rewrite(datasets).path, "/datasets/foo/bar/resolve/main/data.json")
    }

    func testMirrorRewritesAlternateOfficialHosts() {
        setMode(.mirror)
        XCTAssertEqual(HFEndpoint.rewrite(URL(string: "https://hf.co/foo/bar")!).host, "hf-mirror.com")
        XCTAssertEqual(HFEndpoint.rewrite(URL(string: "https://www.huggingface.co/foo/bar")!).host, "hf-mirror.com")
    }

    func testMirrorDoesNotRewriteOtherHosts() {
        setMode(.mirror)
        let other = URL(string: "https://example.com/api/models?search=qwen")!
        XCTAssertEqual(HFEndpoint.rewrite(other), other)
        // CDN hosts come from redirects the mirror handles itself; never touch them.
        let cdn = URL(string: "https://cdn-lfs.huggingface.co/repos/ab/cd/blob")!
        XCTAssertEqual(HFEndpoint.rewrite(cdn), cdn)
        let loopback = URL(string: "http://127.0.0.1:8080/completion")!
        XCTAssertEqual(HFEndpoint.rewrite(loopback), loopback)
    }

    // MARK: - Custom endpoint validation

    func testCustomEndpointValidation() {
        XCTAssertEqual(HFEndpoint.validatedCustomBase("https://my-mirror.example.com")?.absoluteString,
                       "https://my-mirror.example.com")
        XCTAssertEqual(HFEndpoint.validatedCustomBase("  https://my-mirror.example.com  ")?.absoluteString,
                       "https://my-mirror.example.com")
        XCTAssertEqual(HFEndpoint.validatedCustomBase("https://my-mirror.example.com/")?.absoluteString,
                       "https://my-mirror.example.com")
        XCTAssertEqual(HFEndpoint.validatedCustomBase("https://proxy.corp:8443")?.absoluteString,
                       "https://proxy.corp:8443")
        XCTAssertNil(HFEndpoint.validatedCustomBase(""))
        XCTAssertNil(HFEndpoint.validatedCustomBase("http://insecure.example.com"))
        XCTAssertNil(HFEndpoint.validatedCustomBase("https://proxy.example.com/hf"))
        XCTAssertNil(HFEndpoint.validatedCustomBase("https://user:pass@proxy.example.com"))
        XCTAssertNil(HFEndpoint.validatedCustomBase("not a url"))
    }

    func testInvalidCustomFallsBackToOfficial() {
        setMode(.custom, customURL: "http://insecure.example.com/path")
        XCTAssertNil(HFEndpoint.baseURL)
        XCTAssertEqual(HFEndpoint.webBaseString, "https://huggingface.co")
        let url = URL(string: "https://huggingface.co/api/models")!
        XCTAssertEqual(HFEndpoint.rewrite(url), url)
    }

    func testCustomEndpointPreservesPort() {
        setMode(.custom, customURL: "https://proxy.corp:8443")
        let url = URL(string: "https://huggingface.co/foo/bar/resolve/main/f.gguf?download=1")!
        XCTAssertEqual(HFEndpoint.rewrite(url).absoluteString,
                       "https://proxy.corp:8443/foo/bar/resolve/main/f.gguf?download=1")
    }

    // MARK: - Authorization gating

    func testTokenAlwaysSentToOfficialHost() {
        XCTAssertTrue(HFEndpoint.shouldSendAuthorization(to: URL(string: "https://huggingface.co/api/models")!))
        setMode(.mirror)
        XCTAssertTrue(HFEndpoint.shouldSendAuthorization(to: URL(string: "https://huggingface.co/api/models")!))
    }

    func testTokenNeverSentToMirror() {
        setMode(.mirror)
        XCTAssertFalse(HFEndpoint.shouldSendAuthorization(to: URL(string: "https://hf-mirror.com/api/models")!))
        setMode(.custom, customURL: "https://proxy.corp:8443")
        XCTAssertFalse(HFEndpoint.shouldSendAuthorization(to: URL(string: "https://proxy.corp:8443/api/models")!))
    }

    func testRequestRewriteStripsAuthorizationForMirror() {
        setMode(.mirror)
        var req = URLRequest(url: URL(string: "https://huggingface.co/foo/bar/resolve/main/f.gguf")!)
        req.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let rewritten = HFEndpoint.rewrite(req)
        XCTAssertEqual(rewritten.url?.host, "hf-mirror.com")
        XCTAssertNil(rewritten.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestRewriteKeepsAuthorizationForOfficial() {
        var req = URLRequest(url: URL(string: "https://huggingface.co/foo/bar/resolve/main/f.gguf")!)
        req.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let rewritten = HFEndpoint.rewrite(req)
        XCTAssertEqual(rewritten.url?.host, "huggingface.co")
        XCTAssertEqual(rewritten.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testRequestRewriteLeavesNonHFRequestsAlone() {
        setMode(.mirror)
        var req = URLRequest(url: URL(string: "https://api.example.com/v1/data")!)
        req.setValue("Bearer other-service", forHTTPHeaderField: "Authorization")
        let rewritten = HFEndpoint.rewrite(req)
        XCTAssertEqual(rewritten.url?.host, "api.example.com")
        XCTAssertEqual(rewritten.value(forHTTPHeaderField: "Authorization"), "Bearer other-service")
    }

    // MARK: - Environment export

    func testApplyEnvironmentSetsAndClearsHFEndpoint() {
        // getenv reads the live environ; ProcessInfo.environment may be cached.
        setMode(.mirror)
        HFEndpoint.applyEnvironment()
        XCTAssertEqual(getenv("HF_ENDPOINT").map { String(cString: $0) }, "https://hf-mirror.com")
        setMode(.official)
        HFEndpoint.applyEnvironment()
        XCTAssertNil(getenv("HF_ENDPOINT"))
    }
}
