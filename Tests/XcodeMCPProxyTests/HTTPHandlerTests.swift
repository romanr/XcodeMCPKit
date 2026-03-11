import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import XcodeMCPProxyCore
import XcodeMCPProxySession
import XcodeMCPProxyUpstream
import XcodeMCPProxyXcodeSupport

@testable import XcodeMCPProxyTransportHTTP

@Suite
struct HTTPHandlerTests {
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

    @Test func httpDebugUpstreamsReturnsSnapshot() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProxyDebugSnapshot.self, from: Data(response.body.utf8))
        #expect(snapshot.proxyInitialized == false)
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].upstreamIndex == 0)
    }

    @Test func httpDebugUpstreamsReturnsNotFoundWhenListenerIsNotLoopback() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "not found")
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

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseId = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseId == 1)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.lastChooseUpstreamShouldPin() == true)
        #expect(sessionManager.requestSuccessNotificationCount() == 0)
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
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32600)
        #expect((error?["message"] as? String) == "missing id")
    }

    @Test func httpSingleElementBatchErrorReturnsArrayShape() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/list",
            ]
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
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [[String: Any]])
        #expect(array.count == 1)
        #expect((array[0]["id"] as? NSNumber)?.intValue == 42)
        let error = array[0]["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect((error?["message"] as? String) == "expected initialize request")
    }

    @Test func httpTimeoutReturnsMCPErrorAndCleansMapping() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2001,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(sessionManager.mappedUpstreamRequestCount() == 1)
        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect((error?["message"] as? String) == "upstream timeout")
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
    }

    @Test func httpTimeoutReturnsSSEErrorWhenEventStreamIsPreferred() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2002,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
        #expect(response.body.contains("data:"))
        #expect(response.body.contains("\"code\":-32000"))
    }

    @Test func httpBatchTimeoutCountsHealthPenaltyOnceAndCleansAllMappings() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 2101,
                "method": "tools/list",
            ],
            [
                "jsonrpc": "2.0",
                "id": 2102,
                "method": "tools/list",
            ],
            [
                "jsonrpc": "2.0",
                "id": 2103,
                "method": "tools/list",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(sessionManager.mappedUpstreamRequestCount() == 3)
        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [[String: Any]])
        #expect(array.count == 3)
        for object in array {
            let error = object["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32000)
            #expect((error?["message"] as? String) == "upstream timeout")
        }
        #expect(sessionManager.requestTimeoutNotificationCount() == 1)
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
    }

    @Test func httpReturnsUpstreamUnavailableWhenNoHealthyUpstreamExists() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        sessionManager.setAvailableUpstreamIndex(nil)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3001,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32001)
        #expect((error?["message"] as? String) == "upstream unavailable")
    }

    @Test func httpMalformedJSONReturnsParseErrorBeforeUpstreamUnavailable() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        sessionManager.setAvailableUpstreamIndex(nil)
        let chooseCountBeforeMalformedRequest = sessionManager.chooseUpstreamIndexCallCount()

        var malformedHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        malformedHead.headers.add(name: "Accept", value: "application/json")
        malformedHead.headers.add(name: "Content-Type", value: "application/json")
        malformedHead.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var malformedBody = channel.allocator.buffer(capacity: 20)
        malformedBody.writeString("{\"jsonrpc\":\"2.0\",")
        try channel.writeInbound(HTTPServerRequestPart.head(malformedHead))
        try channel.writeInbound(HTTPServerRequestPart.body(malformedBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32700)
        #expect((error?["message"] as? String) == "invalid json")
        #expect(sessionManager.chooseUpstreamIndexCallCount() == chooseCountBeforeMalformedRequest)
    }

    @Test func httpOverloadedErrorResponseDoesNotMarkRequestSuccess() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config) { method, originalId in
            #expect(method == "tools/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "error": [
                    "code": -32002,
                    "message": "upstream overloaded",
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
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
        let sessionId = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3101,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionId)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
        #expect(sessionManager.requestSuccessNotificationCount() == 0)
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
                "capabilities": [String: Any]()
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
                "capabilities": [String: Any]()
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

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseId = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseId == 2)

        let result = responseObject?["result"] as? [String: Any]
        let tools = result?["tools"] as? [Any]
        #expect(tools?.count == 0)

        #expect(sessionManager.sentUpstreamCount() == 0)
        #expect(sessionManager.assignedUpstreamIdCount() == 0)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 2)
        #expect(sessionManager.lastChooseUpstreamShouldPin() == true)
        #expect(sessionManager.refreshToolsListCallCount() == 0)
    }

    @Test func httpToolsListUsesCachedResultWhenParamsArePresent() async throws {
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
                "capabilities": [String: Any]()
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

        // tools/list with params should still be served from cache (Codex startup stability).
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-1"
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

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseId = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseId == 2)

        let result = responseObject?["result"] as? [String: Any]
        let tools = result?["tools"] as? [Any]
        #expect(tools?.count == 0)

        #expect(sessionManager.sentUpstreamCount() == 0)
        #expect(sessionManager.assignedUpstreamIdCount() == 0)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 2)
        #expect(sessionManager.lastChooseUpstreamShouldPin() == true)
        #expect(sessionManager.refreshToolsListCallCount() == 0)
    }

    @Test func httpToolsListCachesResultOnMissWhenParamsArePresent() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config) { method, originalId in
            #expect(method == "tools/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": [
                    "tools": [Any]()
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
                "capabilities": [String: Any]()
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

        // tools/list should be forwarded on the first miss, then cached even with params.
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-1"
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

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)
        #expect(sessionManager.cachedToolsListResult() != nil)
        #expect(sessionManager.sentUpstreamCount() == 1)

        // Second call should be served from cache (no upstream send).
        let toolsPayload2: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-2"
            ],
        ]
        let toolsData2 = try JSONSerialization.data(withJSONObject: toolsPayload2, options: [])
        var toolsHead2 = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead2.headers.add(name: "Accept", value: "application/json")
        toolsHead2.headers.add(name: "Content-Type", value: "application/json")
        toolsHead2.headers.add(name: "Mcp-Session-Id", value: sessionId!)
        var toolsBody2 = channel.allocator.buffer(capacity: toolsData2.count)
        toolsBody2.writeBytes(toolsData2)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead2))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody2))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse2 = try collectResponse(from: channel)
        #expect(toolsResponse2.head.status == .ok)
        #expect(sessionManager.sentUpstreamCount() == 1)
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
                "capabilities": [String: Any]()
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
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
                "capabilities": [String: Any]()
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect(object?["error"] == nil)
        let result = object?["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpResourcesListRewritesNonStandardErrorResultToEmptyArrayAfterInit() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config) { method, originalId in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "The message contained an unknown method 'resources/list'",
                        ]
                    ],
                    "isError": true,
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
                "capabilities": [String: Any]()
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
            "id": 456,
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
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
                "capabilities": [String: Any]()
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect(object?["result"] == nil)
    }

    @Test func httpResourcesListDoesNotMaskNonMethodNotFoundErrorsWhenNullResultIsPresentAfterInit()
        async throws
    {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config) { method, originalId in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": NSNull(),
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
                "capabilities": [String: Any]()
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
            "id": 124,
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect(object?["result"] is NSNull)
    }

    @Test func httpResourcesListDoesNotRewriteNonStandardErrorResultWithoutUnknownMethodAfterInit()
        async throws
    {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestSessionManager(config: config) { method, originalId in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "permission denied",
                        ]
                    ],
                    "isError": true,
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
                "capabilities": [String: Any]()
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
            "id": 457,
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

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect(object?["error"] == nil)
        let result = object?["result"] as? [String: Any]
        #expect((result?["isError"] as? Bool) == true)
        #expect(result?["resources"] == nil)
    }

    @Test func httpRefreshCodeIssuesSerializesRequestsForSameTabIdentifier() async throws {
        let coordinator = RefreshCodeIssuesCoordinator()
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let secondEntered = NIOLockedValueBox(false)

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                secondEntered.withLockedValue { value in
                    value = true
                }
            }
        }

        await Task.yield()
        await Task.yield()
        #expect(secondEntered.withLockedValue { $0 } == false)

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(secondEntered.withLockedValue { $0 } == true)
    }

    @Test func httpRefreshCodeIssuesKeepsDifferentTabIdentifiersConcurrent() async throws {
        let coordinator = RefreshCodeIssuesCoordinator()
        let firstEntered = AsyncSignal()
        let secondEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-a") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-b") { _ in
                await secondEntered.signal()
            }
        }

        await secondEntered.wait()
        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(Bool(true))
    }

    @Test func httpRefreshCodeIssuesRejectsWhenPerKeyQueueLimitIsExceeded() async throws {
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 8,
            queueWaitTimeout: 5
        )
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let secondEntered = AsyncSignal()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await secondEntered.signal()
            }
        }

        await Task.yield()
        await Task.yield()

        do {
            _ = try await coordinator.withPermit(key: "windowtab-same") { _ in
                ()
            }
            #expect(Bool(false))
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            #expect(Bool(true))
        }

        await releaseFirst.signal()
        await secondEntered.wait()
        _ = await firstTask.value
        _ = await secondTask.value
    }

    @Test func httpRefreshCodeIssuesRejectsWhenGlobalQueueLimitIsExceeded() async throws {
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 4,
            maxPendingTotal: 0,
            queueWaitTimeout: 5
        )
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-a") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        do {
            _ = try await coordinator.withPermit(key: "windowtab-a") { _ in
                ()
            }
            #expect(Bool(false))
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            #expect(Bool(true))
        }

        await releaseFirst.signal()
        _ = await firstTask.value
    }

    @Test func httpRefreshCodeIssuesTimeoutRemovesQueuedWaiter() async throws {
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 4,
            queueWaitTimeout: 0.05
        )
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let thirdEntered = AsyncSignal()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-timeout") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        do {
            _ = try await coordinator.withPermit(key: "windowtab-timeout") { _ in
                ()
            }
            #expect(Bool(false))
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
            #expect(Bool(true))
        }

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-timeout") { _ in
                await thirdEntered.signal()
            }
        }

        await Task.yield()
        await releaseFirst.signal()
        await thirdEntered.wait()
        _ = await firstTask.value
        _ = await thirdTask.value
    }

    @Test func httpRefreshCodeIssuesCancellationRemovesQueuedWaiter() async throws {
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 4,
            queueWaitTimeout: 5
        )
        let firstEntered = AsyncSignal()
        let releaseFirst = AsyncSignal()
        let thirdEntered = AsyncSignal()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-cancel") { _ in
                await firstEntered.signal()
                await releaseFirst.wait()
            }
        }
        await firstEntered.wait()

        let cancelledTask = Task<Void, Error> {
            _ = try await coordinator.withPermit(key: "windowtab-cancel") { _ in
                ()
            }
        }
        await Task.yield()
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.result
        switch cancelledResult {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            #expect(Bool(false))
        }

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-cancel") { _ in
                await thirdEntered.signal()
            }
        }

        await Task.yield()
        await releaseFirst.signal()
        await thirdEntered.wait()
        _ = await firstTask.value
        _ = await thirdTask.value
    }

    @Test func httpRefreshCodeIssuesRetriesSourceEditorErrorFive() async throws {
        let config = makeConfig(requestTimeout: 2)
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalId,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalId, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-retry",
                payload: toolsCallPayload(
                    id: 10,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesRetriesShortSourceEditorErrorFiveText() async throws {
        let config = makeConfig(requestTimeout: 2)
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalId,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalId, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-retry-short",
                payload: toolsCallPayload(
                    id: 13,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-short",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesDoesNotRetryNonRetryableToolError() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalId,
                        text: "permission denied"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-no-retry",
                payload: toolsCallPayload(
                    id: 11,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-no-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpNonTargetToolsCallDoesNotUseRefreshRetryPath() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalId,
                        text:
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-other-tool",
                payload: toolsCallPayload(
                    id: 12,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesReturnsBackpressureErrorWhenQueueIsFull() async throws {
        let config = makeConfig(requestTimeout: 2)
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 0,
            maxPendingTotal: 8,
            queueWaitTimeout: 5
        )
        let firstSent = SyncSignal()
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                firstSent.signal()
                return .manual(try makeToolSuccessResponse(id: originalId, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionId: "session-overload-1",
                    payload: toolsCallPayload(
                        id: 21,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-overload",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            await firstSent.wait()

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-overload-2",
                payload: toolsCallPayload(
                    id: 22,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-overload",
                        "filePath": "B.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesReturnsBackpressureErrorAfterQueueWaitTimeout() async throws {
        let config = makeConfig(requestTimeout: 2)
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 4,
            maxPendingTotal: 8,
            queueWaitTimeout: 0.05
        )
        let firstSent = SyncSignal()
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                firstSent.signal()
                return .manual(try makeToolSuccessResponse(id: originalId, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionId: "session-timeout-1",
                    payload: toolsCallPayload(
                        id: 24,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-timeout",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            await firstSent.wait()

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-timeout-2",
                payload: toolsCallPayload(
                    id: 25,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-timeout",
                        "filePath": "B.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshWarmupInternalWindowLookupDoesNotResetUpstreamSuccessState() async throws {
        let config = makeConfig(requestTimeout: 0.05)
        let attempts = NIOLockedValueBox(0)
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let runner = HTTPHandlerFakeProcessRunner()
        await runner.enqueue(label: "window-title", stdout: "SampleProject — Foo.swift\n")
        await runner.enqueue(label: "source-document-paths", stdout: "")

        let warmupDriver = XcodeEditorWarmupDriver(processRunner: runner)
        let sessionManager = TestSessionManager(
            config: config,
            upstreamPlanResponder: { method, originalId in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalId,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-timeout, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                }
                return .delayed(
                    try makeToolSuccessResponse(id: originalId, text: "late"),
                    delayNanos: 500_000_000
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            warmupDriver: warmupDriver
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionId: "session-internal-window-lookup",
                payload: toolsCallPayload(
                    id: 14,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-timeout",
                        "filePath": "Missing.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let error = body["error"] as? [String: Any]
            #expect(error != nil)
            #expect(sessionManager.sentUpstreamCount() == 2)
            #expect(sessionManager.requestSuccessNotificationCount() == 0)
            #expect(sessionManager.requestTimeoutNotificationCount() == 1)
            #expect(sessionManager.chooseUpstreamShouldPinValues() == [false, true])
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

private enum HTTPTestError: Error {
    case missingResponseHead
}

private struct UpstreamResponsePlan {
    let data: Data
    let delayNanos: UInt64?
    let deliverManually: Bool

    static func immediate(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: false)
    }

    static func delayed(
        _ data: Data,
        delayNanos: UInt64
    ) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: delayNanos, deliverManually: false)
    }

    static func manual(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: true)
    }
}

private actor HTTPHandlerFakeProcessRunner: ProcessRunning {
    private struct PlannedOutput {
        let label: String
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private var plannedOutputs: [PlannedOutput] = []

    func enqueue(
        label: String,
        stdout: String = "",
        stderr: String = "",
        terminationStatus: Int32 = 0
    ) {
        plannedOutputs.append(
            PlannedOutput(
                label: label,
                stdout: stdout,
                stderr: stderr,
                terminationStatus: terminationStatus
            )
        )
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        guard plannedOutputs.isEmpty == false else {
            return ProcessOutput(terminationStatus: 1, stdout: "", stderr: "no output")
        }
        let next = plannedOutputs.removeFirst()
        #expect(next.label == request.label)
        return ProcessOutput(
            terminationStatus: next.terminationStatus,
            stdout: next.stdout,
            stderr: next.stderr
        )
    }
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
        struct PendingResponse: Sendable {
            let sessionId: String
            let data: Data
        }

        var sessions: [String: SessionContext] = [:]
        var nextUpstreamId: Int64 = 1
        var assignUpstreamIdCount = 0
        var initialized = false
        var cachedToolsList: JSONValue?
        var refreshToolsListCalls = 0
        var upstreamSendCount = 0
        var upstreamIdMapping: [Int64: UpstreamMapping] = [:]
        var chooseUpstreamCalls: [ChooseUpstreamCall] = []
        var availableUpstreamIndex: Int? = 0
        var requestTimeoutNotifications = 0
        var requestSuccessNotifications = 0
        var pendingResponses: [PendingResponse] = []
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let upstreamResponder:
        (@Sendable (_ method: String, _ originalId: RPCId) throws -> UpstreamResponsePlan)?
    private let legacyUpstreamResponder:
        (@Sendable (_ method: String, _ originalId: RPCId) throws -> Data)?

    init(
        config: ProxyConfig,
        upstreamResponder: (@Sendable (_ method: String, _ originalId: RPCId) throws -> Data)? = nil
    ) {
        self.config = config
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = upstreamResponder
    }

    init(
        config: ProxyConfig,
        upstreamPlanResponder: (@Sendable (_ method: String, _ originalId: RPCId) throws -> UpstreamResponsePlan)?
    ) {
        self.config = config
        self.upstreamResponder = upstreamPlanResponder
        self.legacyUpstreamResponder = nil
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

    func refreshToolsListIfNeeded() {
        state.withLockedValue { state in
            state.refreshToolsListCalls += 1
        }
    }

    func registerInitialize(
        sessionId: String,
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        state.withLockedValue { state in
            state.initialized = true
        }
        _ = chooseUpstreamIndex(sessionId: sessionId, shouldPin: true)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": [
                "capabilities": [String: Any]()
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return eventLoop.makeSucceededFuture(buffer)
    }

    func chooseUpstreamIndex(sessionId: String, shouldPin: Bool) -> Int? {
        state.withLockedValue { state in
            state.chooseUpstreamCalls.append(
                ChooseUpstreamCall(sessionId: sessionId, shouldPin: shouldPin)
            )
            return state.availableUpstreamIndex
        }
    }

    func assignUpstreamId(sessionId: String, originalId: RPCId, upstreamIndex _: Int) -> Int64 {
        state.withLockedValue { state in
            state.assignUpstreamIdCount += 1
            let id = state.nextUpstreamId
            state.nextUpstreamId += 1
            state.upstreamIdMapping[id] = UpstreamMapping(
                sessionId: sessionId, originalId: originalId)
            return id
        }
    }

    func removeUpstreamIdMapping(sessionId: String, requestIdKey: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            let removed = state.upstreamIdMapping.first { _, mapping in
                mapping.sessionId == sessionId && mapping.originalId.key == requestIdKey
            }?.key
            if let removed {
                state.upstreamIdMapping.removeValue(forKey: removed)
            }
        }
    }

    func onRequestTimeout(sessionId: String, requestIdKey: String, upstreamIndex: Int) {
        state.withLockedValue { state in
            state.requestTimeoutNotifications += 1
        }
        removeUpstreamIdMapping(
            sessionId: sessionId, requestIdKey: requestIdKey, upstreamIndex: upstreamIndex)
    }

    func onRequestSucceeded(sessionId _: String, requestIdKey _: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            state.requestSuccessNotifications += 1
        }
    }

    func sendUpstream(_ data: Data, upstreamIndex _: Int) {
        state.withLockedValue { state in
            state.upstreamSendCount += 1
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let method = object["method"] as? String,
            let upstreamIdValue = object["id"]
        else {
            return
        }
        let upstreamId = (upstreamIdValue as? NSNumber)?.int64Value ?? (upstreamIdValue as? Int64)
        guard let upstreamId,
            let mapping = state.withLockedValue({ $0.upstreamIdMapping[upstreamId] })
        else {
            return
        }

        let responsePlan: UpstreamResponsePlan
        if let upstreamResponder,
            let planned = try? upstreamResponder(method, mapping.originalId)
        {
            responsePlan = planned
        } else if let legacyUpstreamResponder,
            let responseData = try? legacyUpstreamResponder(method, mapping.originalId)
        {
            responsePlan = .immediate(responseData)
        } else {
            return
        }

        let deliverResponse = { [self] in
            let session = self.session(id: mapping.sessionId)
            session.router.handleIncoming(responsePlan.data)
        }
        if responsePlan.deliverManually {
            state.withLockedValue { state in
                state.pendingResponses.append(
                    State.PendingResponse(
                        sessionId: mapping.sessionId,
                        data: responsePlan.data
                    )
                )
            }
        } else if let delayNanos = responsePlan.delayNanos {
            Task {
                try? await Task.sleep(nanoseconds: delayNanos)
                deliverResponse()
            }
        } else {
            deliverResponse()
        }
    }

    func debugSnapshot() -> ProxyDebugSnapshot {
        ProxyDebugSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            proxyInitialized: isInitialized(),
            cachedToolsListAvailable: cachedToolsListResult() != nil,
            warmupInFlight: false,
            upstreams: [
                ProxyUpstreamDebugSnapshot(
                    upstreamIndex: 0,
                    isInitialized: isInitialized(),
                    initInFlight: false,
                    didSendInitialized: false,
                    healthState: "healthy",
                    consecutiveRequestTimeouts: 0,
                    consecutiveToolsListFailures: 0,
                    lastToolsListSuccessUptimeNs: nil,
                    recentStderr: [],
                    lastDecodeError: nil,
                    lastBridgeError: nil,
                    resyncCount: 0,
                    lastResyncAt: nil,
                    lastResyncDroppedBytes: nil,
                    lastResyncPreview: nil,
                    bufferedStdoutBytes: 0
                )
            ],
            recentTraffic: []
        )
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

    func chooseUpstreamShouldPinValues() -> [Bool] {
        state.withLockedValue { $0.chooseUpstreamCalls.map(\.shouldPin) }
    }

    func refreshToolsListCallCount() -> Int {
        state.withLockedValue { $0.refreshToolsListCalls }
    }

    func mappedUpstreamRequestCount() -> Int {
        state.withLockedValue { $0.upstreamIdMapping.count }
    }

    func setAvailableUpstreamIndex(_ value: Int?) {
        state.withLockedValue { $0.availableUpstreamIndex = value }
    }

    func requestTimeoutNotificationCount() -> Int {
        state.withLockedValue { $0.requestTimeoutNotifications }
    }

    func requestSuccessNotificationCount() -> Int {
        state.withLockedValue { $0.requestSuccessNotifications }
    }

    func setInitialized(_ value: Bool) {
        state.withLockedValue { $0.initialized = value }
    }

    func deliverNextPendingResponse() {
        let pending = state.withLockedValue { state -> State.PendingResponse? in
            guard state.pendingResponses.isEmpty == false else { return nil }
            return state.pendingResponses.removeFirst()
        }
        guard let pending else { return }
        let session = session(id: pending.sessionId)
        session.router.handleIncoming(pending.data)
    }
}

private func makeConfig(
    maxBodyBytes: Int = 1024,
    requestTimeout: TimeInterval = 1
) -> ProxyConfig {
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

private func makeHTTPTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any SessionManaging,
    refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
    warmupDriver: XcodeEditorWarmupDriver = .disabled()
) throws {
    let handler = HTTPHandler(
        config: config,
        sessionManager: sessionManager,
        refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
        warmupDriver: warmupDriver
    )
    try channel.pipeline.addHandler(handler).wait()
}

private func collectResponse(from channel: EmbeddedChannel) throws -> (
    head: HTTPResponseHead, body: String
) {
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

private func advanceEventLoopTime(on channel: EmbeddedChannel, by amount: TimeAmount) {
    channel.embeddedEventLoop.advanceTime(by: amount)
}

private func toolsCallPayload(
    id: Int,
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
}

private func postJSON(
    _ payload: [String: Any],
    sessionId: String,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionId)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

private struct TestHTTPHandlerServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: any SessionManaging

    static func start(
        config: ProxyConfig,
        sessionManager: any SessionManaging,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        warmupDriver: XcodeEditorWarmupDriver = .disabled()
    ) throws -> TestHTTPHandlerServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager,
                            refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
                            warmupDriver: warmupDriver
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: 0).wait()
        let port = channel.localAddress?.port ?? 0
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return TestHTTPHandlerServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager
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

private func postHTTPJSON(
    url: URL,
    sessionId: String,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw HTTPTestError.missingResponseHead
    }
    let object =
        (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
        ?? [:]
    return (httpResponse, object)
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard signaled == false else { return }
        signaled = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class SyncSignal: @unchecked Sendable {
    private struct State {
        var signaled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = NIOLockedValueBox(State())

    func wait() async {
        if state.withLockedValue({ $0.signaled }) {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = state.withLockedValue { state in
                if state.signaled {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuations = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            guard state.signaled == false else { return [] }
            state.signaled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func makeToolSuccessResponse(id: RPCId, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ]
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func makeToolErrorResponse(id: RPCId, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ],
            "isError": true,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}
