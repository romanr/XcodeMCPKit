import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import XcodeMCPProxy

@Test func httpHealthCheck() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.body == "ok")
}

@Test func httpSSERequiresAcceptHeader() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .notAcceptable)
    #expect(response.body.contains("text/event-stream"))
}

@Test func httpPostRejectsUnknownAccept() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "text/plain")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .notAcceptable)
}

@Test func httpPostRejectsNonJSONContentType() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "text/plain")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .unsupportedMediaType)
}

@Test func httpPostRejectsLargeBody() async throws {
    let config = makeConfig(maxBodyBytes: 1)
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .payloadTooLarge)
}

@Test func httpInitializeCreatesSessionAndReturnsResponse() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)

    let responseObject = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let responseId = (responseObject?["id"] as? NSNumber)?.intValue
    #expect(responseId == 1)
}

@Test func httpInitializePrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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
    head.headers.add(name: "Accept", value: "application/json, text/event-stream")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Content-Type") == "application/json")
}

@Test func httpInitializeRequiresId() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .badRequest)
    #expect(response.body.contains("missing id"))
}

@Test func httpSessionHeaderAutoCreatesSession() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 99,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: "missing-session")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Mcp-Session-Id") == "missing-session")
    #expect(response.body.contains("\"result\""))
}

@Test func httpSSEHandshakeSucceedsWithSession() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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

@Test func httpToolsListUsesCachedResultWhenAvailable() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    sessionManager.setCachedToolsListResult(
        JSONValue(any: ["tools": [Any]()])!
    )
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    // Initialize to establish a session id.
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    let sessionId = initResponse.head.headers.first(name: "Mcp-Session-Id")
    #expect(sessionId?.isEmpty == false)

    // tools/list should be served from cache and not forwarded upstream.
    let toolsPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
    ]
    let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

    var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    toolsHead.headers.add(name: "Accept", value: "application/json")
    toolsHead.headers.add(name: "Content-Type", value: "application/json")
    toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionId!)
    var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
    toolsBody.writeBytes(toolsData)
    try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
    try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let toolsResponse = try collectResponse(from: channel)
    #expect(toolsResponse.head.status == .ok)

    let responseObject = try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: []) as? [String: Any]
    let responseId = (responseObject?["id"] as? NSNumber)?.intValue
    #expect(responseId == 2)

    let result = responseObject?["result"] as? [String: Any]
    let tools = result?["tools"] as? [Any]
    #expect(tools?.count == 0)

    #expect(sessionManager.sentUpstreamCount() == 0)
    #expect(sessionManager.assignedUpstreamIdCount() == 0)
    #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
    #expect(sessionManager.lastChooseUpstreamShouldPin() == true)
}

@Test func httpToolsListForwardsWhenParamsArePresentEvenIfCacheExists() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    sessionManager.setCachedToolsListResult(
        JSONValue(any: ["tools": [Any]()])!
    )
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    // Initialize to establish a session id.
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    let sessionId = initResponse.head.headers.first(name: "Mcp-Session-Id")
    #expect(sessionId?.isEmpty == false)

    // tools/list with params should not be served from cache.
    let toolsPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": [
            "cursor": "cursor-1",
        ],
    ]
    let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

    var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    toolsHead.headers.add(name: "Accept", value: "application/json")
    toolsHead.headers.add(name: "Content-Type", value: "application/json")
    toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionId!)
    var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
    toolsBody.writeBytes(toolsData)
    try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
    try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    #expect(sessionManager.sentUpstreamCount() == 1)
    #expect(sessionManager.assignedUpstreamIdCount() == 1)
}

@Test func httpToolsListPrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    sessionManager.setCachedToolsListResult(
        JSONValue(any: ["tools": [Any]()])!
    )
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    // Initialize to establish a session id.
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    let sessionId = initResponse.head.headers.first(name: "Mcp-Session-Id")
    #expect(sessionId?.isEmpty == false)

    let toolsPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
    ]
    let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

    var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
    toolsHead.headers.add(name: "Content-Type", value: "application/json")
    toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionId!)
    var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
    toolsBody.writeBytes(toolsData)
    try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
    try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let toolsResponse = try collectResponse(from: channel)
    #expect(toolsResponse.head.status == .ok)
    #expect(toolsResponse.head.headers.first(name: "Content-Type") == "application/json")
}

@Test func httpResourcesListReturnsEmptyArray() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "resources/list",
        "params": [String: Any](),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: "session-1")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Content-Type") == "application/json")

    let object = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let responseId = (object?["id"] as? NSNumber)?.intValue
    #expect(responseId == 1)
    let result = object?["result"] as? [String: Any]
    let resources = result?["resources"] as? [Any]
    #expect(resources?.isEmpty == true)
}

@Test func httpResourceTemplatesListReturnsEmptyArray() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "resources/templates/list",
        "params": [String: Any](),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: "session-1")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Content-Type") == "application/json")

    let object = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let responseId = (object?["id"] as? NSNumber)?.intValue
    #expect(responseId == 1)
    let result = object?["result"] as? [String: Any]
    let templates = result?["resourceTemplates"] as? [Any]
    #expect(templates?.isEmpty == true)
}

@Test func httpResourcesListRewritesMethodNotFoundErrorToEmptyArrayAfterInit() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config) { method, originalId in
        #expect(method == "resources/list")
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "error": [
                "code": -32601,
                "message": "Method not found",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [])
    }
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    // Initialize to establish a session id.
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    let sessionId = initResponse.head.headers.first(name: "Mcp-Session-Id")
    #expect(sessionId?.isEmpty == false)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 123,
        "method": "resources/list",
        "params": [String: Any](),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionId!)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)

    let object = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    #expect(object?["error"] == nil)
    let result = object?["result"] as? [String: Any]
    let resources = result?["resources"] as? [Any]
    #expect(resources?.isEmpty == true)
}

@Test func httpResourcesListDoesNotMaskNonMethodNotFoundErrorsAfterInit() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config) { method, originalId in
        #expect(method == "resources/list")
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "error": [
                "code": -32000,
                "message": "permission denied",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [])
    }
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    // Initialize to establish a session id.
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any](),
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    let sessionId = initResponse.head.headers.first(name: "Mcp-Session-Id")
    #expect(sessionId?.isEmpty == false)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 123,
        "method": "resources/list",
        "params": [String: Any](),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionId!)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)

    let object = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let error = object?["error"] as? [String: Any]
    #expect((error?["code"] as? NSNumber)?.intValue == -32000)
    #expect(object?["result"] == nil)
}

private enum HTTPTestError: Error {
    case missingResponseHead
}

private final class TestSessionManager: SessionManaging {
    private struct UpstreamMapping: Sendable {
        let sessionId: String
        let originalId: RPCId
    }

    private struct ChooseUpstreamCall: Sendable {
        let sessionId: String
        let shouldPin: Bool
    }

    private struct State: Sendable {
        var sessions: [String: SessionContext] = [:]
        var nextUpstreamId: Int64 = 1
        var assignUpstreamIdCount = 0
        var initialized = false
        var cachedToolsList: JSONValue?
        var upstreamSendCount = 0
        var upstreamIdMapping: [Int64: UpstreamMapping] = [:]
        var chooseUpstreamCalls: [ChooseUpstreamCall] = []
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let upstreamResponder: (@Sendable (_ method: String, _ originalId: RPCId) throws -> Data)?

    init(
        config: ProxyConfig,
        upstreamResponder: (@Sendable (_ method: String, _ originalId: RPCId) throws -> Data)? = nil
    ) {
        self.config = config
        self.upstreamResponder = upstreamResponder
    }

    func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = context
            return context
        }
    }

    func hasSession(id: String) -> Bool {
        state.withLockedValue { state in
            state.sessions[id] != nil
        }
    }

    func removeSession(id: String) {
        let context = state.withLockedValue { state in
            state.sessions.removeValue(forKey: id)
        }
        context?.notificationHub.closeAll()
    }

    func shutdown() {}

    func isInitialized() -> Bool {
        state.withLockedValue { state in
            state.initialized
        }
    }

    func cachedToolsListResult() -> JSONValue? {
        state.withLockedValue { $0.cachedToolsList }
    }

    func setCachedToolsListResult(_ result: JSONValue) {
        state.withLockedValue { state in
            state.cachedToolsList = result
        }
    }

    func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        state.withLockedValue { state in
            state.initialized = true
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": [
                "capabilities": [String: Any](),
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return eventLoop.makeSucceededFuture(buffer)
    }

    func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int {
        state.withLockedValue { state in
            state.chooseUpstreamCalls.append(
                ChooseUpstreamCall(sessionId: sessionId, shouldPin: shouldPin)
            )
        }
        return 0
    }

    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex _: Int) -> Int64 {
        state.withLockedValue { state in
            state.assignUpstreamIdCount += 1
            let id = state.nextUpstreamId
            state.nextUpstreamId += 1
            state.upstreamIdMapping[id] = UpstreamMapping(sessionId: sessionId, originalId: originalId)
            return id
        }
    }

    func sendUpstream(_ data: Data, upstreamIndex _: Int) {
        state.withLockedValue { state in
            state.upstreamSendCount += 1
        }

        guard let upstreamResponder else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let method = object["method"] as? String,
              let upstreamIdValue = object["id"] else {
            return
        }
        let upstreamId = (upstreamIdValue as? NSNumber)?.int64Value ?? (upstreamIdValue as? Int64)
        guard let upstreamId,
              let mapping = state.withLockedValue({ $0.upstreamIdMapping[upstreamId] }),
              let responseData = try? upstreamResponder(method, mapping.originalId) else {
            return
        }

        let session = self.session(id: mapping.sessionId)
        session.router.handleIncoming(responseData)
    }

    func sentUpstreamCount() -> Int {
        state.withLockedValue { $0.upstreamSendCount }
    }

    func assignedUpstreamIdCount() -> Int {
        state.withLockedValue { $0.assignUpstreamIdCount }
    }

    func chooseUpstreamIndexCallCount() -> Int {
        state.withLockedValue { $0.chooseUpstreamCalls.count }
    }

    func lastChooseUpstreamShouldPin() -> Bool {
        state.withLockedValue { $0.chooseUpstreamCalls.last?.shouldPin ?? false }
    }
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
    sessionManager: any SessionManaging
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
