import Foundation
import NIO
import NIOHTTP1
import Testing
@testable import XcodeMCPProxy

@Test func httpConcurrentInitializeRequests() async throws {
    let server = try TestHTTPServer.start()
    defer { Task { await server.shutdown() } }
    let url = server.url

    let count = 20
    let results = try await withThrowingTaskGroup(of: (String, Int).self) { group in
        for index in 0..<count {
            group.addTask {
                let payload = initializePayload(id: index + 1)
                let (response, body) = try await postJSON(url: url, sessionId: nil, payload: payload)
                guard let sessionId = response.value(forHTTPHeaderField: "Mcp-Session-Id") else {
                    throw ConcurrencyTestError.missingSessionId
                }
                let responseId = (body["id"] as? NSNumber)?.intValue ?? -1
                return (sessionId, responseId)
            }
        }

        var sessionIds: [String] = []
        var ids: [Int] = []
        for try await (sessionId, responseId) in group {
            sessionIds.append(sessionId)
            ids.append(responseId)
        }
        return (sessionIds, ids)
    }

    #expect(Set(results.0).count == count)
    #expect(Set(results.1).count == count)
}

@Test func httpConcurrentRequestsShareSession() async throws {
    let server = try TestHTTPServer.start()
    defer { Task { await server.shutdown() } }
    let url = server.url

    let (initializeResponse, initializeBody) = try await postJSON(
        url: url,
        sessionId: nil,
        payload: initializePayload(id: 1)
    )
    guard let sessionId = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id") else {
        throw ConcurrencyTestError.missingSessionId
    }
    let initId = (initializeBody["id"] as? NSNumber)?.intValue ?? -1
    #expect(initId == 1)

    let count = 20
    let responseIds = try await withThrowingTaskGroup(of: Int.self) { group in
        for index in 0..<count {
            group.addTask {
                let payload: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": index + 100,
                    "method": "tools/list",
                ]
                let (response, body) = try await postJSON(
                    url: url,
                    sessionId: sessionId,
                    payload: payload
                )
                guard response.statusCode == 200 else {
                    throw ConcurrencyTestError.invalidResponse
                }
                return (body["id"] as? NSNumber)?.intValue ?? -1
            }
        }

        var ids: [Int] = []
        for try await responseId in group {
            ids.append(responseId)
        }
        return ids
    }

    #expect(Set(responseIds).count == count)
}

private enum ConcurrencyTestError: Error {
    case invalidResponse
    case missingSessionId
}

private struct TestHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: SessionManager
    let upstream: EchoUpstreamClient

    static func start() throws -> TestHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: "xcrun",
            upstreamArgs: ["mcpbridge"],
            xcodePID: nil,
            upstreamSessionID: nil,
            maxBodyBytes: 1_048_576,
            requestTimeout: 5,
            eagerInitialize: false
        )
        let upstream = EchoUpstreamClient()
        let sessionManager = SessionManager(config: config, eventLoop: group.next(), upstream: upstream)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
        let port = channel.localAddress?.port ?? config.listenPort
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return TestHTTPServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            upstream: upstream
        )
    }

    func shutdown() async {
        sessionManager.shutdown()
        channel.close(promise: nil)
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

private actor EchoUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return
        }
        var responses: [Data] = []
        if let object = json as? [String: Any] {
            if let response = makeResponse(from: object) {
                responses.append(response)
            }
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let response = makeResponse(from: object) {
                    responses.append(response)
                }
            }
        }

        for response in responses {
            continuation.yield(.message(response))
        }
    }

    private func makeResponse(from object: [String: Any]) -> Data? {
        guard let id = object["id"] else {
            return nil
        }
        let method = object["method"] as? String
        let result: [String: Any]
        if method == "initialize" {
            result = ["capabilities": [String: Any]()]
        } else {
            result = [:]
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private func initializePayload(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-concurrency-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func postJSON(
    url: URL,
    sessionId: String?,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let sessionId {
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw ConcurrencyTestError.invalidResponse
    }
    let object = (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any] ?? [:]
    return (httpResponse, object)
}
