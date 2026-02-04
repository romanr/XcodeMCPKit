import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import XcodeMCPProxy

@Test func httpHealthCheck() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.body == "ok")
}

@Test func httpSSERequiresAcceptHeader() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .notAcceptable)
    #expect(response.body.contains("text/event-stream"))
}

@Test func httpPostRejectsUnknownAccept() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "text/plain")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .notAcceptable)
}

@Test func httpPostRejectsNonJSONContentType() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "text/plain")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .unsupportedMediaType)
}

@Test func httpPostRejectsLargeBody() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig(maxBodyBytes: 1)
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .payloadTooLarge)
}

@Test func httpInitializeCreatesSessionAndReturnsResponse() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-tests",
                "version": "0.0",
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    try await Task.yield()
    let sent = await upstream.sent()
    #expect(sent.count == 1)

    let upstreamRequest = try JSONSerialization.jsonObject(with: sent[0], options: []) as? [String: Any]
    let upstreamId = (upstreamRequest?["id"] as? NSNumber)?.int64Value
    #expect(upstreamId != nil)

    let responsePayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": upstreamId ?? 0,
        "result": [
            "capabilities": [String: Any](),
        ],
    ]
    let responseData = try JSONSerialization.data(withJSONObject: responsePayload, options: [])
    await upstream.yield(.message(responseData))
    runEmbeddedLoop(from: channel)

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)

    let responseObject = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let responseId = (responseObject?["id"] as? NSNumber)?.intValue
    #expect(responseId == 1)
}

@Test func httpInitializeRequiresId() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-tests",
                "version": "0.0",
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .badRequest)
    #expect(response.body.contains("missing id"))
}

@Test func httpSessionHeaderMustExist() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 99,
        "method": "tools/list",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: "missing-session")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(.byteBuffer(body)))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .unauthorized)
    #expect(response.body.contains("session not found"))
}

@Test func httpSSEHandshakeSucceedsWithSession() async throws {
    let upstream = TestUpstreamClient()
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = SessionManager(config: config, eventLoop: channel.eventLoop, upstream: upstream)
    _ = sessionManager.session(id: "session-1")
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
    head.headers.add(name: "Accept", value: "text/event-stream")
    head.headers.add(name: "Mcp-Session-Id", value: "session-1")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
    #expect(response.body.contains(": ok"))
}

private enum HTTPTestError: Error {
    case missingResponseHead
}

private func makeConfig(maxBodyBytes: Int = 1024, requestTimeout: TimeInterval = 1) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        xcodePID: nil,
        upstreamSessionID: nil,
        maxBodyBytes: maxBodyBytes,
        requestTimeout: requestTimeout,
        eagerInitialize: false
    )
}

private func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: SessionManager
) throws {
    let handler = HTTPHandler(config: config, sessionManager: sessionManager)
    try channel.pipeline.addHandler(handler).wait()
}

private func collectResponse(from channel: EmbeddedChannel) throws -> (head: HTTPResponseHead, body: String) {
    var responseHead: HTTPResponseHead?
    var bodyBuffer = channel.allocator.buffer(capacity: 0)

    while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
        switch part {
        case .head(let head):
            responseHead = head
        case .body(let body):
            switch body {
            case .byteBuffer(var buffer):
                bodyBuffer.writeBuffer(&buffer)
            case .fileRegion:
                break
            }
        case .end:
            break
        }
    }

    guard let responseHead else {
        throw HTTPTestError.missingResponseHead
    }
    let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
    return (responseHead, body)
}

private func runEmbeddedLoop(from channel: EmbeddedChannel) {
    if let embedded = channel.eventLoop as? EmbeddedEventLoop {
        embedded.run()
    }
}
