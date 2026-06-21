import Foundation
import Network
import RelayKit
import Darwin
#if canImport(UIKit)
import UIKit
#endif

protocol RelayHTTPServing: Actor {
    func currentState() -> RelayHTTPServer.State
    func start() async throws
    func stop() async
    func updateConfiguration(_ configuration: RelayServerConfiguration, restart: Bool) async throws
}

actor RelayHTTPServer {
    struct State: Equatable {
        var isRunning: Bool
        var bindHost: String
        var port: UInt16?
        var reachableLANAddress: String?
    }

    private let engine: RelayServerEngine
    private var configuration: RelayServerConfiguration
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RelayHTTPConnection] = [:]
    private var state = State(isRunning: false, bindHost: "127.0.0.1", port: nil, reachableLANAddress: nil)
    @MainActor private var service: NetService?
    private let networkQueue = DispatchQueue(label: "Noema.RelayHTTPServer.network")
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "Noema.RelayHTTPServer.path")

    init(engine: RelayServerEngine, configuration: RelayServerConfiguration) {
        self.engine = engine
        self.configuration = configuration
    }

    /// Resolve the active port, preferring the listener's assigned value.
    /// Keeps `state.port` in sync so downstream callers don't see `0`.
    private func resolvedPort() -> UInt16? {
        if let port = state.port, port > 0 { return port }
        if let listenerPort = listener?.port?.rawValue, listenerPort > 0 {
            state.port = listenerPort
            return listenerPort
        }
        let configured = configuration.port
        return configured > 0 ? configured : nil
    }

    func currentState() -> State {
        _ = resolvedPort()
        refreshReachableLANAddress(reason: "state-query")
        return state
    }

    func start() async throws {
        await stop()
        await engine.updateConfiguration(configuration)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = configuration.port
        let listener: NWListener
        do {
            if let nwPort = NWEndpoint.Port(rawValue: port), port != 0 {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            RelayLog.record(category: "RelayHTTPServer", message: "Failed to start listener: \(error.localizedDescription)")
            throw error
        }

        listener.stateUpdateHandler = { [weak self] newState in
            Task { await self?.handle(state: newState) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }

        listener.start(queue: networkQueue)
        self.listener = listener
        state.bindHost = configuration.bindHost
        state.isRunning = true
        startPathMonitorIfNeeded()
        await publishServiceIfNeeded()
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        state.isRunning = false
        state.port = nil
        state.reachableLANAddress = nil
        stopPathMonitor()
        await unpublishService()
    }

    func updateConfiguration(_ configuration: RelayServerConfiguration, restart: Bool = true) async throws {
        self.configuration = configuration
        await engine.updateConfiguration(configuration)
        if configuration.serveOnLocalNetwork {
            startPathMonitorIfNeeded()
            refreshReachableLANAddress(reason: "config-update")
        } else {
            stopPathMonitor()
            if state.reachableLANAddress != nil {
                state.reachableLANAddress = nil
                RelayLog.record(category: "RelayHTTPServer", message: "LAN address cleared (config-update)")
            }
        }
        if restart, state.isRunning {
            try await start()
        }
    }

    private func handle(state newState: NWListener.State) async {
        switch newState {
        case .ready:
            let port = listener?.port?.rawValue ?? configuration.port
            state.port = port
            if (state.port ?? 0) == 0, let resolved = resolvedPort() {
                state.port = resolved
            }
            refreshReachableLANAddress(reason: "listener-ready")
            let loggedPort = state.port ?? port
            RelayLog.record(category: "RelayHTTPServer", message: "Server listening on \(configuration.bindHost):\(loggedPort)")
        case .failed(let error):
            RelayLog.record(category: "RelayHTTPServer", message: "Listener failed: \(error.localizedDescription)")
            await stop()
        case .cancelled:
            RelayLog.record(category: "RelayHTTPServer", message: "Listener cancelled")
            await stop()
        default:
            break
        }
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        guard configuration.serveOnLocalNetwork else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.refreshReachableLANAddress(reason: "path-change") }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func refreshReachableLANAddress(reason: String) {
        guard state.isRunning else { return }
        guard configuration.serveOnLocalNetwork else { return }
        guard let port = resolvedPort(), port > 0 else { return }
        let resolved = Self.primaryLANAddress(bindHost: configuration.bindHost, port: port)
        if state.reachableLANAddress == resolved { return }
        if let resolved {
            let message = state.reachableLANAddress == nil
                ? "LAN address assigned (\(reason)): \(resolved)"
                : "LAN address updated (\(reason)): \(resolved)"
            RelayLog.record(category: "RelayHTTPServer",
                             message: message,
                             style: .lanTransition)
        } else if state.reachableLANAddress != nil {
            RelayLog.record(category: "RelayHTTPServer",
                             message: "LAN address unavailable (\(reason))",
                             style: .lanTransition)
        }
        state.reachableLANAddress = resolved
    }

    private func handle(connection nwConnection: NWConnection) async {
        let connection = RelayHTTPConnection(connection: nwConnection,
                                             configuration: configuration,
                                             engine: engine,
                                             delegate: self)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(on: networkQueue)
    }

    fileprivate func connectionDidFinish(_ connection: RelayHTTPConnection) {
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
    }

    private func publishServiceIfNeeded() async {
        guard configuration.advertiseBonjour, configuration.serveOnLocalNetwork, let port = state.port else {
            await unpublishService()
            return
        }
        await MainActor.run {
            self.service?.stop()
            let svc = NetService(domain: "local.", type: "_noema._tcp.", name: Self.serviceName(), port: Int32(port))
            svc.publish()
            self.service = svc
        }
    }

    private func unpublishService() async {
        await MainActor.run {
            self.service?.stop()
            self.service = nil
        }
    }

    static func primaryLANAddress(bindHost: String, port: UInt16) -> String? {
        guard port > 0 else { return nil }
        if bindHost == "127.0.0.1" { return "http://127.0.0.1:\(port)" }

        // Gather candidate IPv4 interfaces and prefer Wi‑Fi (en0), then other en*.
        struct Candidate { let name: String; let ip: String; let priority: Int }

        func priority(for name: String) -> Int {
            // Lower is better
            if name == "en0" { return 0 }            // Wi‑Fi primary
            if name.hasPrefix("en") { return 1 }     // Other Ethernet/Wi‑Fi
            if name.hasPrefix("awdl") { return 3 }   // AWDL/AirDrop
            if name.hasPrefix("utun") { return 4 }   // VPN
            if name.hasPrefix("p2p") { return 5 }    // Peer-to-peer
            if name.hasPrefix("llw") { return 6 }    // Low latency Wi‑Fi
            return 8
        }

        var candidates: [Candidate] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0 else { continue }
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // Skip obviously non-routable or virtual interfaces
            if name.hasPrefix("bridge") || name.hasPrefix("ap") { continue }

            var addr = sa.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(&addr,
                           socklen_t(sa.pointee.sa_len),
                           &hostname,
                           socklen_t(hostname.count),
                           nil,
                           0,
                           NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if ip != "127.0.0.1" {
                    candidates.append(Candidate(name: name, ip: ip, priority: priority(for: name)))
                }
            }
        }

        guard let best = candidates.sorted(by: { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            // Stable preference if priorities tie: en0, then lexical
            if lhs.name == "en0" { return true }
            if rhs.name == "en0" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }).first else {
            return nil
        }
        return "http://\(best.ip):\(port)"
    }

    private static func serviceName() -> String {
#if os(macOS)
        return Host.current().localizedName ?? "Noema Relay"
#elseif canImport(UIKit)
        return UIDevice.current.name
#else
        return "Noema Relay"
#endif
    }
}

extension RelayHTTPServer: RelayHTTPServing {}

fileprivate func makeMetadata(from request: HTTPRequest,
                              remoteDescription: String,
                              transport: RelayServerEngine.ClientTransport,
                              originOverride: String?) -> RelayServerEngine.RequestMetadata {
    func headerValue(_ key: String) -> String? {
        guard let value = request.header(named: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    return RelayServerEngine.RequestMetadata(
        clientAddress: remoteDescription,
        origin: originOverride ?? headerValue("Origin"),
        userAgent: headerValue("User-Agent"),
        clientID: headerValue("X-Noema-Client-ID"),
        clientName: headerValue("X-Noema-Client-Name"),
        clientModel: headerValue("X-Noema-Client-Model"),
        clientPlatform: headerValue("X-Noema-Client-Platform"),
        clientSSID: headerValue("X-Noema-Client-SSID"),
        transport: transport
    )
}

private final class RelayHTTPConnection {
    private enum RequestState {
        case waiting
        case headers(Data)
        case body(HTTPRequest, Data)
        case chunked(HTTPRequest, Data)
        case streaming
    }

    private let connection: NWConnection
    private var state: RequestState = .waiting
    private let configuration: RelayServerConfiguration
    private let engine: RelayServerEngine
    private weak var delegate: RelayHTTPServer?
    private var buffer = Data()
    private var expectedBodyLength: Int = 0
    private var isClosed = false
    private let closeLock = NSLock()
    private var currentOrigin: String?
    private let remoteDescription: String
    private let remoteHost: String?

    private static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            return address.debugDescription
        @unknown default:
            return host.debugDescription
        }
    }

    private static func remoteInfo(for endpoint: NWEndpoint) -> (host: String?, description: String) {
        switch endpoint {
        case .hostPort(let host, let port):
            let hostString = hostString(from: host)
            return (hostString, "\(hostString):\(port.rawValue)")
        case .service(let name, let type, let domain, _):
            let desc = "\(name).\(type).\(domain)"
            return (desc, desc)
        default:
            return (nil, endpoint.debugDescription)
        }
    }

    init(connection: NWConnection,
         configuration: RelayServerConfiguration,
         engine: RelayServerEngine,
         delegate: RelayHTTPServer) {
        let info = RelayHTTPConnection.remoteInfo(for: connection.endpoint)
        self.connection = connection
        self.configuration = configuration
        self.engine = engine
        self.delegate = delegate
        self.remoteDescription = info.description
        self.remoteHost = info.host
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            if case .failed(let error) = newState {
                let key = "connfail-\(remoteHost ?? remoteDescription)"
                RelayLog.recordThrottled(category: "RelayHTTPServer",
                                         key: key,
                                         minInterval: 1.0,
                                         message: "Connection failed: \(error.localizedDescription)")
                self.cancel()
            }
            if case .cancelled = newState {
                self.cancel()
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func cancel() {
        // cancel() is reachable from the network queue (state handler) and from
        // response Tasks (send completions). Make the close transition atomic so
        // we never double-cancel or remove the connection from the delegate twice.
        closeLock.lock()
        if isClosed {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        connection.cancel()
        if let delegate {
            Task { await delegate.connectionDidFinish(self) }
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if let error {
                let key = "recv-\(remoteHost ?? remoteDescription)"
                RelayLog.recordThrottled(category: "RelayHTTPServer",
                                         key: key,
                                         minInterval: 1.0,
                                         message: "Receive error: \(error.localizedDescription)")
                self.cancel()
                return
            }
            if isComplete {
                self.cancel()
                return
            }
            self.receiveNext()
        }
    }

    private func processBuffer() {
        switch state {
        case .waiting:
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            guard let request = HTTPRequest(headerData: headerData) else {
                send(status: 400, json: ["error": "Malformed request"])
                return
            }
            expectedBodyLength = request.contentLength
            if expectedBodyLength == 0 {
                let isChunked = request.header(named: "transfer-encoding")?
                    .lowercased().contains("chunked") ?? false
                if isChunked {
                    state = .chunked(request, Data())
                    processBuffer()
                } else {
                    handle(request: request, body: Data())
                }
            } else {
                state = .body(request, Data())
                processBuffer()
            }
        case .chunked(let request, let initialBody):
            // Decode HTTP/1.1 chunked transfer-encoding: <hex-size>CRLF<data>CRLF…,
            // terminated by a zero-length chunk.
            var body = initialBody
            while true {
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                    state = .chunked(request, body)
                    return
                }
                let sizeLineData = buffer.subdata(in: 0..<lineEnd.lowerBound)
                let sizeToken = String(data: sizeLineData, encoding: .utf8)?
                    .split(separator: ";").first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let chunkSize = Int(sizeToken, radix: 16) else {
                    send(status: 400, json: ["error": "Malformed chunk size"])
                    return
                }
                if chunkSize == 0 {
                    // Consume the terminating chunk line and an optional final CRLF
                    // (we ignore trailer headers).
                    buffer.removeSubrange(0..<lineEnd.upperBound)
                    if let trailerEnd = buffer.range(of: Data("\r\n".utf8)), trailerEnd.lowerBound == 0 {
                        buffer.removeSubrange(0..<trailerEnd.upperBound)
                    }
                    state = .waiting
                    handle(request: request, body: body)
                    return
                }
                let dataStart = lineEnd.upperBound
                let needed = dataStart + chunkSize + 2 // chunk bytes + trailing CRLF
                if buffer.count < needed {
                    state = .chunked(request, body)
                    return
                }
                body.append(buffer.subdata(in: dataStart..<(dataStart + chunkSize)))
                buffer.removeSubrange(0..<needed)
            }
        case .body(let request, var body):
            let needed = expectedBodyLength - body.count
            if needed > 0, buffer.count < needed { return }
            let chunk = buffer.prefix(needed)
            body.append(chunk)
            buffer.removeFirst(chunk.count)
            if body.count >= expectedBodyLength {
                state = .waiting
                handle(request: request, body: body)
            } else {
                state = .body(request, body)
                processBuffer()
            }
        case .streaming:
            break
        case .headers:
            break
        }
    }

    private func handle(request: HTTPRequest, body: Data) {
        currentOrigin = request.header(named: "origin")
        guard authorize(request) else {
            send(status: 401, json: ["error": "Unauthorized"])
            return
        }
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            handleOptions()
        case ("GET", "/health"), ("GET", "/v1/health"), ("GET", "/api/v0/health"):
            send(status: 200, json: ["status": "ok"])
        case ("GET", "/v1/models"):
            Task {
                let models = await engine.modelSnapshots()
                let response = OpenAIModelListResponse(from: models)
                if let data = try? JSONEncoder().encode(response) {
                    send(status: 200, body: data, contentType: "application/json")
                } else {
                    send(status: 500, json: ["error": "Encoding error"])
                }
            }
        case ("POST", "/v1/chat/completions"):
            logLANHandshake(for: request)
            handleChatCompletion(request: request, body: body)
        case ("POST", "/v1/completions"):
            handleTextCompletion(request: request, body: body)
        case ("POST", "/api/v0/responses"):
            handleResponses(request: request, body: body)
        default:
            send(status: 404, json: ["error": "Not found"])
        }
    }

    private func handleOptions() {
        var headers: [String: String] = [
            "Allow": "GET,POST,OPTIONS",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization"
        ]
        if let origin = configuration.corsAllowedOrigin(for: currentOrigin) {
            headers["Access-Control-Allow-Origin"] = origin
        }
        sendRawHeader(status: 204, headers: headers)
        cancel()
    }

    private func logLANHandshake(for request: HTTPRequest) {
        guard let transport = request.header(named: "x-noema-transport")?.lowercased(), transport == "lan" else {
            return
        }
        let ssid = request.header(named: "x-noema-client-ssid") ?? "unknown"
        let device = request.header(named: "x-noema-relay-device") ?? "unknown"
        let origin = currentOrigin ?? "unknown"
        RelayLog.record(category: "RelayHTTPServer",
                        message: "LAN upgrade request from \(remoteDescription) ssid=\(ssid) device=\(device) origin=\(origin)",
                        style: .lanTransition)
    }

    private func handleChatCompletion(request: HTTPRequest, body: Data) {
        guard let payload = try? JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: body) else {
            send(status: 400, json: ["error": "Invalid JSON"])
            return
        }
        // Noema Relay does not support images/multimodal content via remote endpoints.
        let hasImageMarkers = payload.messages.contains { msg in
            if msg.containsImage { return true }
            let t = msg.content.lowercased()
            return t.contains("<image>") || t.contains("image_url") || t.contains("![") || t.contains("data:image/")
        }
        if hasImageMarkers {
            send(status: 400, json: ["error": "Images are not supported by Noema Relay endpoints."])
            return
        }
        let parameters = payload.normalizedParameters()
        let metadata = makeMetadata(from: request,
                                    remoteDescription: remoteDescription,
                                    transport: .lan,
                                    originOverride: currentOrigin)
        Task {
            await engine.registerClient(metadata: metadata)
        }
        let messages = payload.messages.map { ChatMessage(role: $0.role, content: $0.content) }
        let requestID = UUID().uuidString
        let chatRequest = RelayServerEngine.ChatCompletionRequest(requestID: requestID,
                                                                  modelID: payload.model,
                                                                  messages: messages,
                                                                  parameters: parameters,
                                                                  stream: payload.stream ?? false,
                                                                  user: payload.user,
                                                                  metadata: metadata)
        if payload.stream == true {
            state = .streaming
            Task {
                do {
                    let stream = try await engine.streamChat(chatRequest)
                    sendStream(stream: stream, modelID: payload.model)
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        } else {
            Task {
                do {
                    let result = try await engine.performChat(chatRequest)
                    let response = OpenAIChatCompletionResponse(result: result)
                    if let data = try? JSONEncoder().encode(response) {
                        send(status: 200, body: data, contentType: "application/json")
                    } else {
                        send(status: 500, json: ["error": "Encoding error"])
                    }
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        }
    }

    private func handleTextCompletion(request: HTTPRequest, body: Data) {
        guard let payload = try? JSONDecoder().decode(OpenAITextCompletionRequest.self, from: body) else {
            send(status: 400, json: ["error": "Invalid JSON"])
            return
        }
        // Reject multimodal/image placeholders in text completions as well
        let promptText = payload.promptText()
        let pt = promptText.lowercased()
        if pt.contains("<image>") || pt.contains("image_url") || pt.contains("![") || pt.contains("data:image/") {
            send(status: 400, json: ["error": "Images are not supported by Noema Relay endpoints."])
            return
        }
        let parameters = payload.normalizedParameters()
        let metadata = makeMetadata(from: request,
                                    remoteDescription: remoteDescription,
                                    transport: .lan,
                                    originOverride: currentOrigin)
        Task {
            await engine.registerClient(metadata: metadata)
        }
        let requestID = UUID().uuidString
        let textRequest = RelayServerEngine.TextCompletionRequest(requestID: requestID,
                                                                  modelID: payload.model,
                                                                  prompt: promptText,
                                                                  parameters: parameters,
                                                                  stream: payload.stream ?? false,
                                                                  user: payload.user,
                                                                  metadata: metadata)
        if payload.stream == true {
            state = .streaming
            Task {
                do {
                    let stream = try await engine.streamTextCompletion(textRequest)
                    sendStream(stream: stream, modelID: payload.model)
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        } else {
            Task {
                do {
                    let result = try await engine.performTextCompletion(textRequest)
                    let response = OpenAITextCompletionResponse(result: result)
                    if let data = try? JSONEncoder().encode(response) {
                        send(status: 200, body: data, contentType: "application/json")
                    } else {
                        send(status: 500, json: ["error": "Encoding error"])
                    }
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        }
    }

    private func handleResponses(request: HTTPRequest, body: Data) {
        guard let payload = try? JSONDecoder().decode(OpenAIResponsesRequest.self, from: body) else {
            send(status: 400, json: ["error": "Invalid JSON"])
            return
        }
        let parameters = payload.normalizedParameters()
        let metadata = makeMetadata(from: request,
                                    remoteDescription: remoteDescription,
                                    transport: .lan,
                                    originOverride: currentOrigin)
        Task {
            await engine.registerClient(metadata: metadata)
        }
        let request = RelayServerEngine.ResponsesRequest(requestID: UUID().uuidString,
                                                         modelID: payload.model,
                                                         message: ChatMessage(role: payload.input.role, content: payload.input.content),
                                                         previousResponseID: payload.previousResponseID,
                                                         parameters: parameters,
                                                         stream: payload.stream ?? false,
                                                         user: payload.user,
                                                         metadata: metadata)
        if payload.stream == true {
            state = .streaming
            Task {
                do {
                    let stream = try await engine.streamResponse(request)
                    sendStream(stream: stream, modelID: payload.model)
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        } else {
            Task {
                do {
                    let result = try await engine.performResponse(request)
                    let response = OpenAIResponsesResponse(result: result)
                    if let data = try? JSONEncoder().encode(response) {
                        send(status: 200, body: data, contentType: "application/json")
                    } else {
                        send(status: 500, json: ["error": "Encoding error"])
                    }
                } catch {
                    send(status: 500, json: ["error": error.localizedDescription])
                }
            }
        }
    }

    /// Loopback clients (tools running on the host itself) are trusted without a
    /// token. Any other origin — i.e. an actual LAN peer — must present the
    /// bearer token, including on macOS, where the relay binds to 0.0.0.0 and is
    /// Bonjour-advertised.
    private var isLoopbackClient: Bool {
        guard let host = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return host == "127.0.0.1"
            || host == "::1"
            || host == "localhost"
            || host.hasPrefix("127.")
            || host == "0:0:0:0:0:0:0:1"
    }

    private func authorize(_ request: HTTPRequest) -> Bool {
        if isLoopbackClient { return true }
        guard configuration.requiresAuth(for: request.path) else { return true }
        guard let header = request.header(named: "Authorization") else { return false }
        let expected = "Bearer \(configuration.apiToken)"
        return header == expected
    }

    private func sendStream(stream: AsyncThrowingStream<RelayServerEngine.StreamEvent, Error>, modelID: String) {
        var headers: [String: String] = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
        ]
        if let origin = configuration.corsAllowedOrigin(for: currentOrigin) {
            headers["Access-Control-Allow-Origin"] = origin
        }
        sendRawHeader(status: 200, headers: headers)
        Task {
            do {
                for try await event in stream {
                    let payload: Data
                    switch event {
                    case .delta(let chunk):
                        let chunkResponse = OpenAIStreamChunk(model: modelID, delta: chunk)
                        payload = chunkResponse.encode()
                    case .completion(let result):
                        let completion = OpenAIStreamFinalChunk(result: result)
                        payload = completion.encode()
                    }
                    let data = Data("data: ".utf8) + payload + Data("\n\n".utf8)
                    try await sendData(data)
                }
                let done = Data("data: [DONE]\n\n".utf8)
                try await sendData(done)
                cancel()
            } catch {
                RelayLog.recordThrottled(category: "RelayHTTPServer",
                                         key: "stream-\(modelID)",
                                         minInterval: 0.5,
                                         message: "Streaming error: \(error.localizedDescription)")
                cancel()
            }
        }
    }

    private func send(status: Int, json: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            cancel()
            return
        }
        send(status: status, body: data, contentType: "application/json")
    }

    private func send(status: Int, body: Data, contentType: String) {
        var headers: [String: String] = [
            "Content-Length": "\(body.count)",
            "Content-Type": contentType
        ]
        if let origin = configuration.corsAllowedOrigin(for: currentOrigin) {
            headers["Access-Control-Allow-Origin"] = origin
        }
        sendRawHeader(status: status, headers: headers)
        connection.send(content: body, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func sendRawHeader(status: Int, headers: [String: String]) {
        var responseLines: [String] = []
        responseLines.append("HTTP/1.1 \(status) \(HTTPStatus.reason(for: status))")
        for (key, value) in headers {
            responseLines.append("\(key): \(value)")
        }
        responseLines.append("")
        responseLines.append("")
        let data = responseLines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

private struct HTTPStatus {
    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "HTTP"
        }
    }
}

extension RelayHTTPConnection: @unchecked Sendable {}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int

    init?(headerData: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        self.method = String(parts[0])
        self.path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let sepIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<sepIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: sepIndex)...].trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }
        self.headers = headers
        if let lengthString = headers["content-length"], let length = Int(lengthString) {
            self.contentLength = length
        } else {
            self.contentLength = 0
        }
    }

    func header(named name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Flattens an OpenAI message/`input` `content` field that may be a plain
/// string, an array of typed content parts, or null. Text parts are joined;
/// the presence of any image part is tracked so callers can reject multimodal
/// requests (which Noema Relay does not serve remotely).
private struct FlexibleContent: Decodable {
    let text: String
    let containsImage: Bool

    private struct Part: Decodable {
        let type: String?
        let text: String?

        var isImage: Bool {
            guard let type = type?.lowercased() else { return false }
            return type.contains("image")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            text = ""
            containsImage = false
        } else if let string = try? container.decode(String.self) {
            text = string
            containsImage = false
        } else if let parts = try? container.decode([Part].self) {
            text = parts.compactMap { $0.text }.joined(separator: "\n")
            containsImage = parts.contains { $0.isImage }
        } else {
            text = ""
            containsImage = false
        }
    }
}

private struct OpenAIChatCompletionRequest: Decodable {
    struct Message: Decodable {
        var role: String
        var content: String
        var containsImage: Bool

        enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            if let flexible = try container.decodeIfPresent(FlexibleContent.self, forKey: .content) {
                content = flexible.text
                containsImage = flexible.containsImage
            } else {
                content = ""
                containsImage = false
            }
        }
    }

    var model: String
    var messages: [Message]
    var stream: Bool?
    var temperature: Double?
    var top_p: Double?
    var top_k: Int?
    var max_tokens: Int?
    var stop: StopParameter?
    var presence_penalty: Double?
    var frequency_penalty: Double?
    var seed: Int?
    var user: String?

    enum StopParameter: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .single(string)
            } else if let array = try? container.decode([String].self) {
                self = .multiple(array)
            } else {
                self = .multiple([])
            }
        }

        var values: [String] {
            switch self {
            case .single(let value): return [value]
            case .multiple(let array): return array
            }
        }
    }

    func normalizedParameters() -> RelayServerEngine.NormalizedParameters {
        RelayServerEngine.NormalizedParameters(temperature: temperature,
                                               topP: top_p,
                                               topK: top_k,
                                               maxTokens: max_tokens,
                                               stop: stop?.values ?? [],
                                               presencePenalty: presence_penalty,
                                               frequencyPenalty: frequency_penalty,
                                               seed: seed)
    }
}

private struct OpenAITextCompletionRequest: Decodable {
    var model: String
    var prompt: Prompt
    var stream: Bool?
    var temperature: Double?
    var top_p: Double?
    var top_k: Int?
    var max_tokens: Int?
    var stop: OpenAIChatCompletionRequest.StopParameter?
    var presence_penalty: Double?
    var frequency_penalty: Double?
    var seed: Int?
    var user: String?

    enum Prompt: Decodable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([String].self) {
                self = .array(array)
            } else {
                self = .string("")
            }
        }
    }

    func promptText() -> String {
        switch prompt {
        case .string(let text): return text
        case .array(let array): return array.joined(separator: "\n")
        }
    }

    func normalizedParameters() -> RelayServerEngine.NormalizedParameters {
        RelayServerEngine.NormalizedParameters(temperature: temperature,
                                               topP: top_p,
                                               topK: top_k,
                                               maxTokens: max_tokens,
                                               stop: stop?.values ?? [],
                                               presencePenalty: presence_penalty,
                                               frequencyPenalty: frequency_penalty,
                                               seed: seed)
    }
}

private struct OpenAIResponsesRequest: Decodable {
    struct Input: Decodable {
        var role: String
        var content: String

        enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? "user"
            content = (try container.decodeIfPresent(FlexibleContent.self, forKey: .content))?.text ?? ""
        }
    }

    var model: String
    var input: Input
    var previousResponseID: String?
    var stream: Bool?
    var temperature: Double?
    var top_p: Double?
    var top_k: Int?
    var max_tokens: Int?
    var stop: OpenAIChatCompletionRequest.StopParameter?
    var presence_penalty: Double?
    var frequency_penalty: Double?
    var seed: Int?
    var user: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case previousResponseID = "previous_response_id"
        case stream
        case temperature
        case top_p
        case top_k
        case max_tokens
        case stop
        case presence_penalty
        case frequency_penalty
        case seed
        case user
    }

    func normalizedParameters() -> RelayServerEngine.NormalizedParameters {
        RelayServerEngine.NormalizedParameters(temperature: temperature,
                                               topP: top_p,
                                               topK: top_k,
                                               maxTokens: max_tokens,
                                               stop: stop?.values ?? [],
                                               presencePenalty: presence_penalty,
                                               frequencyPenalty: frequency_penalty,
                                               seed: seed)
    }
}

private struct OpenAIModelListResponse: Encodable {
    struct Model: Encodable {
        var id: String
        var object: String
        var created: Int
        var owned_by: String
    }

    var object = "list"
    var data: [Model]

    init(from snapshots: [RelayServerEngine.ModelSnapshot]) {
        data = snapshots.map { snapshot in
            Model(id: snapshot.id,
                  object: "model",
                  created: Int(snapshot.created.timeIntervalSince1970),
                  owned_by: snapshot.ownedBy)
        }
    }
}

private struct OpenAIChatCompletionResponse: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        var index: Int
        var message: Message
        var finish_reason: String
    }
    struct Usage: Encodable {
        var prompt_tokens: Int
        var completion_tokens: Int
        var total_tokens: Int
    }

    var id: String
    var object = "chat.completion"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage

    init(result: RelayServerEngine.ChatCompletionResult) {
        id = result.id
        created = Int(result.created.timeIntervalSince1970)
        self.model = result.modelID
        choices = [
            Choice(index: 0,
                   message: Choice.Message(role: result.message.role, content: result.message.content),
                   finish_reason: result.finishReason)
        ]
        usage = Usage(prompt_tokens: result.usage.promptTokens,
                      completion_tokens: result.usage.completionTokens,
                      total_tokens: result.usage.totalTokens)
    }
}

private struct OpenAITextCompletionResponse: Encodable {
    struct Choice: Encodable {
        var index: Int
        var text: String
        var finish_reason: String
    }
    struct Usage: Encodable {
        var prompt_tokens: Int
        var completion_tokens: Int
        var total_tokens: Int
    }

    var id: String
    var object = "text_completion"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage

    init(result: RelayServerEngine.ChatCompletionResult) {
        id = result.id
        created = Int(result.created.timeIntervalSince1970)
        self.model = result.modelID
        choices = [
            Choice(index: 0,
                   text: result.message.content,
                   finish_reason: result.finishReason)
        ]
        usage = Usage(prompt_tokens: result.usage.promptTokens,
                      completion_tokens: result.usage.completionTokens,
                      total_tokens: result.usage.totalTokens)
    }
}

private struct OpenAIResponsesResponse: Encodable {
    var id: String
    var object = "responses"
    var created: Int
    var model: String
    var output: [OpenAIChatCompletionResponse.Choice.Message]
    var usage: OpenAIChatCompletionResponse.Usage

    init(result: RelayServerEngine.ResponsesResult) {
        id = result.responseID
        created = Int(result.chatResult.created.timeIntervalSince1970)
        self.model = result.chatResult.modelID
        output = [
            OpenAIChatCompletionResponse.Choice.Message(role: result.chatResult.message.role,
                                                        content: result.chatResult.message.content)
        ]
        usage = OpenAIChatCompletionResponse.Usage(prompt_tokens: result.chatResult.usage.promptTokens,
                                                   completion_tokens: result.chatResult.usage.completionTokens,
                                                   total_tokens: result.chatResult.usage.totalTokens)
    }
}

private struct OpenAIStreamChunk: Encodable {
    struct Choice: Encodable {
        struct Delta: Encodable {
            var content: String
        }
        var index: Int
        var delta: Delta
        var finish_reason: String?
    }

    var id: String
    var object = "chat.completion.chunk"
    var created: Int
    var model: String
    var choices: [Choice]

    init(model: String, delta: String) {
        id = "chatcmpl-stream-\(UUID().uuidString.prefix(8))"
        created = Int(Date().timeIntervalSince1970)
        self.model = model
        choices = [
            Choice(index: 0,
                   delta: Choice.Delta(content: delta),
                   finish_reason: nil)
        ]
    }

    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

private struct OpenAIStreamFinalChunk: Encodable {
    struct Choice: Encodable {
        struct Delta: Encodable {
            var content: String?
        }
        var index: Int
        var delta: Delta
        var finish_reason: String?
    }
    struct Usage: Encodable {
        var prompt_tokens: Int
        var completion_tokens: Int
        var total_tokens: Int
    }

    var id: String
    var object = "chat.completion.chunk"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage

    init(result: RelayServerEngine.ChatCompletionResult) {
        id = result.id
        created = Int(result.created.timeIntervalSince1970)
        self.model = result.modelID
        choices = [
            Choice(index: 0,
                   delta: Choice.Delta(content: nil),
                   finish_reason: result.finishReason)
        ]
        usage = Usage(prompt_tokens: result.usage.promptTokens,
                      completion_tokens: result.usage.completionTokens,
                      total_tokens: result.usage.totalTokens)
    }

    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
