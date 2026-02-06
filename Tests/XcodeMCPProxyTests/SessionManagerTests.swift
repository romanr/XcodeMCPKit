import Foundation
import NIO
import Testing
@testable import XcodeMCPProxy

@Test func sessionManagerQueuesInitializeRequests() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 5)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let request1 = makeInitializeRequest(id: 1)
    let request2 = makeInitializeRequest(id: 2)
    let future1 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 1))!,
        requestObject: request1,
        on: eventLoop
    )
    let future2 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: request2,
        on: eventLoop
    )

    await Task.yield()
    let sent = await upstream.sent()
    #expect(sent.count == 1)

    let upstreamId = try extractUpstreamId(from: sent[0])
    let response = try makeInitializeResponse(id: upstreamId)
    await upstream.yield(.message(response))

    let response1 = try decodeJSON(from: try await future1.get())
    let response2 = try decodeJSON(from: try await future2.get())
    let id1 = (response1["id"] as? NSNumber)?.intValue
    let id2 = (response2["id"] as? NSNumber)?.intValue
    #expect(id1 == 1)
    #expect(id2 == 2)
}

@Test func sessionManagerTimeoutResetsInitState() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 1)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let request = makeInitializeRequest(id: 1)
    let future = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 1))!,
        requestObject: request,
        on: eventLoop
    )
    await Task.yield()
    #expect((await upstream.sent()).count == 1)

    try await Task.sleep(nanoseconds: 1_500_000_000)

    do {
        _ = try await future.get()
        #expect(Bool(false))
    } catch {
        #expect(error is TimeoutError)
    }

    _ = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    await Task.yield()
    #expect((await upstream.sent()).count == 2)
}

@Test func sessionManagerEagerInitializeRestartsAfterExit() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 5)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])
    #expect(manager.isInitialized() == false)

    await Task.yield()
    #expect((await upstream.sent()).count == 1)

    await upstream.yield(.exit(1))
    try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
    #expect((await upstream.sent()).count == 2)
}

@Test func sessionManagerSendsInitializedOnce() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 5)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let request = makeInitializeRequest(id: 1)
    let future = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 1))!,
        requestObject: request,
        on: eventLoop
    )

    await Task.yield()
    let sent = await upstream.sent()
    let upstreamId = try extractUpstreamId(from: sent[0])
    let response = try makeInitializeResponse(id: upstreamId)
    await upstream.yield(.message(response))

    _ = try await future.get()
    await Task.yield()

    let afterInit = await upstream.sent()
    #expect(afterInit.count == 2)

    let cached = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    let cachedResponse = try decodeJSON(from: try await cached.get())
    let cachedId = (cachedResponse["id"] as? NSNumber)?.intValue
    #expect(cachedId == 2)
    #expect((await upstream.sent()).count == 2)
}

@Test func sessionManagerPrimaryExitClearsCachedInitializeResult() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 5)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    // First init establishes the cached init result.
    let init1 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 1))!,
        requestObject: makeInitializeRequest(id: 1),
        on: eventLoop
    )
    await Task.yield()
    #expect((await upstream.sent()).count == 1)
    let upstreamId1 = try extractUpstreamId(from: (await upstream.sent())[0])
    await upstream.yield(.message(try makeInitializeResponse(id: upstreamId1)))
    _ = try await init1.get()

    // Wait for notifications/initialized.
    try await waitForSentCount(upstream, count: 2, timeoutSeconds: 1)

    // Simulate primary upstream dying after init succeeded.
    await upstream.yield(.exit(1))
    await Task.yield()

    // A new downstream initialize must trigger a new upstream initialize (no cached response).
    let init2 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    try await waitForSentCount(upstream, count: 3, timeoutSeconds: 1)
    let upstreamId2 = try extractUpstreamId(from: (await upstream.sent())[2])
    await upstream.yield(.message(try makeInitializeResponse(id: upstreamId2)))
    _ = try await init2.get()
}

@Test func sessionManagerSecondaryExitClearsCachedInitializeResultWhenPrimaryAlreadyDown() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 5)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // First init establishes the cached init result (primary only).
    let init1 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 1))!,
        requestObject: makeInitializeRequest(id: 1),
        on: eventLoop
    )
    await Task.yield()
    #expect((await upstream0.sent()).count == 1)
    let upstreamId0 = try extractUpstreamId(from: (await upstream0.sent())[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: upstreamId0)))
    _ = try await init1.get()

    // Warm init -> upstream1
    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 1)
    let init1Messages = await upstream1.sent()
    let upstreamId1 = try extractUpstreamId(from: init1Messages[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: upstreamId1)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 1)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 1)

    // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
    await upstream0.yield(.exit(1))
    await Task.yield()

    // Now simulate the last initialized upstream dying too.
    await upstream1.yield(.exit(1))
    await Task.yield()

    // A new downstream initialize must trigger a new upstream initialize (no cached response).
    let init2 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 1)
    let upstreamId2 = try extractUpstreamId(from: (await upstream0.sent())[2])
    await upstream0.yield(.message(try makeInitializeResponse(id: upstreamId2)))
    _ = try await init2.get()
}

@Test func sessionManagerEagerInitializeRerunsPrimaryInitWhenLastInitializedUpstreamExits() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 0.3)
    let _ = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 1)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 1)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 1)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 1)

    // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
    await upstream0.yield(.exit(1))

    // Primary warm init should be attempted, but we simulate it failing.
    try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 1)
    let retry = await upstream0.sent()
    let retryId = try extractUpstreamId(from: retry[2])
    let errorResponse: [String: Any] = [
        "jsonrpc": "2.0",
        "id": retryId,
        "error": [
            "code": -1,
            "message": "warm init failed",
        ],
    ]
    await upstream0.yield(.message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
    try await Task.sleep(nanoseconds: 50_000_000)

    // Now simulate the last initialized upstream dying too. Eager init should kick the global init path again.
    await upstream1.yield(.exit(1))
    try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 1)
}

@Test func sessionManagerRoutesRequestsRoundRobinAcrossUpstreams() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Eager init -> upstream0
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 1)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    // Warm init -> upstream1
    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 1)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 1)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 1)

    let sessionId = "session-1"
    let session = manager.session(id: sessionId)

    let originalA = RPCId(any: NSNumber(value: 100))!
    let originalB = RPCId(any: NSNumber(value: 101))!

    let upstreamIndexA = manager.chooseUpstreamIndex(sessionId: sessionId)
    let upstreamIndexB = manager.chooseUpstreamIndex(sessionId: sessionId)
    #expect(upstreamIndexA != upstreamIndexB)

    let futureA = session.router.registerRequest(idKey: originalA.key, on: eventLoop)
    let upstreamIdA = manager.assignUpstreamId(
        sessionId: sessionId,
        originalId: originalA,
        upstreamIndex: upstreamIndexA
    )
    manager.sendUpstream(try makeToolListRequest(id: upstreamIdA), upstreamIndex: upstreamIndexA)

    let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
    let upstreamIdB = manager.assignUpstreamId(
        sessionId: sessionId,
        originalId: originalB,
        upstreamIndex: upstreamIndexB
    )
    manager.sendUpstream(try makeToolListRequest(id: upstreamIdB), upstreamIndex: upstreamIndexB)

    await yieldMessage(
        try makeToolListResponse(id: upstreamIdA),
        to: upstreamIndexA == 0 ? upstream0 : upstream1
    )
    await yieldMessage(
        try makeToolListResponse(id: upstreamIdB),
        to: upstreamIndexB == 0 ? upstream0 : upstream1
    )

    _ = try await futureA.get()
    _ = try await futureB.get()

    let methods0 = await upstream0.sent().compactMap(methodName(from:))
    let methods1 = await upstream1.sent().compactMap(methodName(from:))
    #expect(methods0.filter { $0 == "tools/list" }.count == 1)
    #expect(methods1.filter { $0 == "tools/list" }.count == 1)
}

@Test func sessionManagerExitClearsMappingsAndKeepsServingOnOtherUpstreams() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 0.3)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 1)
    let init0 = await upstream0.sent()
    await upstream0.yield(.message(try makeInitializeResponse(id: try extractUpstreamId(from: init0[0]))))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 1)
    let init1 = await upstream1.sent()
    await upstream1.yield(.message(try makeInitializeResponse(id: try extractUpstreamId(from: init1[0]))))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 1)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 1)

    let sessionId = "session-1"
    let session = manager.session(id: sessionId)

    // Send a request to upstream1, then kill upstream1 before it can respond.
    let originalA = RPCId(any: NSNumber(value: 200))!
    let futureA = session.router.registerRequest(idKey: originalA.key, on: eventLoop)
    let upstreamIdA = manager.assignUpstreamId(sessionId: sessionId, originalId: originalA, upstreamIndex: 1)
    manager.sendUpstream(try makeToolListRequest(id: upstreamIdA), upstreamIndex: 1)

    await upstream1.yield(.exit(1))

    // The proxy should continue serving on upstream0.
    let originalB = RPCId(any: NSNumber(value: 201))!
    let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
    let upstreamIndexB = manager.chooseUpstreamIndex(sessionId: sessionId)
    #expect(upstreamIndexB == 0)
    let upstreamIdB = manager.assignUpstreamId(sessionId: sessionId, originalId: originalB, upstreamIndex: upstreamIndexB)
    manager.sendUpstream(try makeToolListRequest(id: upstreamIdB), upstreamIndex: upstreamIndexB)
    await upstream0.yield(.message(try makeToolListResponse(id: upstreamIdB)))
    _ = try await futureB.get()

    // A should time out (mapping is cleared on exit, and no response arrives).
    do {
        _ = try await futureA.get()
        #expect(Bool(false))
    } catch {
        #expect(error is TimeoutError)
    }
}

private func makeConfig(eagerInitialize: Bool, requestTimeout: TimeInterval) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        xcodePID: nil,
        upstreamSessionID: nil,
        maxBodyBytes: 1024,
        requestTimeout: requestTimeout,
        eagerInitialize: eagerInitialize
    )
}

private func makeInitializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "session-manager-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func makeInitializeResponse(id: Int64) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "capabilities": [String: Any](),
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func extractUpstreamId(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
}

private func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    var buffer = buffer
    guard let data = buffer.readData(length: buffer.readableBytes) else {
        return [:]
    }
    return (try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
}

private func shutdown(_ group: EventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

private func waitForSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if await upstream.sent().count >= count {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

private func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return nil
    }
    return object["method"] as? String
}

private func makeToolListRequest(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ],
        options: []
    )
}

private func makeToolListResponse(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ],
        options: []
    )
}

private func yieldMessage(_ data: Data, to upstream: TestUpstreamClient) async {
    await upstream.yield(.message(data))
}
