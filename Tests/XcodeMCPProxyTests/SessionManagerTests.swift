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

    try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
    let sent = await upstream.sent()
    #expect(sent.count == 1)
    guard sent.count == 1 else { return }

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
    try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
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
    try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
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
    try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

    // Simulate primary upstream dying after init succeeded.
    await upstream.yield(.exit(1))
    try await waitForCondition(timeoutSeconds: 2) {
        manager.isInitialized() == false
    }

    // A new downstream initialize must trigger a new upstream initialize (no cached response).
    let init2 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
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
    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1Messages = await upstream1.sent()
    let upstreamId1 = try extractUpstreamId(from: init1Messages[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: upstreamId1)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
    await upstream0.yield(.exit(1))
    await Task.yield()

    // Now simulate the last initialized upstream dying too.
    await upstream1.yield(.exit(1))
    await Task.yield()

    // Ensure the cached init result is cleared before asserting that a new downstream initialize
    // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
    // been processed yet on the event loop.
    try await waitForCondition(timeoutSeconds: 2) {
        manager.isInitialized() == false
    }

    // A new downstream initialize must trigger a new upstream initialize (no cached response).
    let init2 = manager.registerInitialize(
        originalId: RPCId(any: NSNumber(value: 2))!,
        requestObject: makeInitializeRequest(id: 2),
        on: eventLoop
    )
    try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
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
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
    await upstream0.yield(.exit(1))

    // Primary warm init should be attempted, but we simulate it failing.
    try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
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
    try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
}

@Test func sessionManagerRetriesEagerInitializeAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 0.3)
    let _ = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Primary exit triggers warm init on primary.
    await upstream0.yield(.exit(1))
    try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
    let retry = await upstream0.sent()
    let retryId = try extractUpstreamId(from: retry[2])

    // While primary warm init is in flight, last initialized upstream exits.
    await upstream1.yield(.exit(1))
    try await Task.sleep(nanoseconds: 50_000_000)

    // Warm init fails with JSON-RPC error.
    let errorResponse: [String: Any] = [
        "jsonrpc": "2.0",
        "id": retryId,
        "error": [
            "code": -1,
            "message": "warm init failed",
        ],
    ]
    await upstream0.yield(.message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))

    // Proxy should restart eager/global init automatically.
    try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
}

@Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Eager init -> upstream0
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    // Warm init -> upstream1
    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    let sessionIdA = "session-A"
    let sessionIdB = "session-B"
    let sessionA = manager.session(id: sessionIdA)
    let sessionB = manager.session(id: sessionIdB)

    let originalA = RPCId(any: NSNumber(value: 100))!
    let originalB = RPCId(any: NSNumber(value: 101))!

    let upstreamIndexA = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdA, shouldPin: true))
    let upstreamIndexB = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdB, shouldPin: true))
    #expect(upstreamIndexA != upstreamIndexB)

    let futureA = sessionA.router.registerRequest(idKey: originalA.key, on: eventLoop)
    let upstreamIdA = manager.assignUpstreamId(
        sessionId: sessionIdA,
        originalId: originalA,
        upstreamIndex: upstreamIndexA
    )
    manager.sendUpstream(try makeToolListRequest(id: upstreamIdA), upstreamIndex: upstreamIndexA)

    let futureB = sessionB.router.registerRequest(idKey: originalB.key, on: eventLoop)
    let upstreamIdB = manager.assignUpstreamId(
        sessionId: sessionIdB,
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

@Test func sessionManagerRoutesUnmappedNotificationsToPinnedSessionsOnly() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Create two sessions and pin them to different upstreams.
    let sessionIdA = "session-A"
    let sessionIdB = "session-B"
    let sessionA = manager.session(id: sessionIdA)
    let sessionB = manager.session(id: sessionIdB)

    let upstreamIndexA = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdA, shouldPin: true))
    let upstreamIndexB = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdB, shouldPin: true))
    #expect(upstreamIndexA != upstreamIndexB)

    // Ensure we're starting from a clean buffer state.
    _ = sessionA.router.drainBufferedNotifications()
    _ = sessionB.router.drainBufferedNotifications()

    let notification = try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/test",
            "params": ["value": 1],
        ],
        options: []
    )

    await yieldMessage(notification, to: upstream0)
    try await Task.sleep(nanoseconds: 50_000_000)

    let pinnedTo0 = upstreamIndexA == 0 ? sessionA : sessionB
    let notPinnedTo0 = upstreamIndexA == 0 ? sessionB : sessionA

    let receivedPinned = pinnedTo0.router.drainBufferedNotifications()
    let receivedOther = notPinnedTo0.router.drainBufferedNotifications()
    #expect(receivedPinned.count == 1)
    #expect(receivedPinned.first == notification)
    #expect(receivedOther.isEmpty)
}

@Test func sessionManagerDropsUnmappedNotificationsWhenNoPinnedTargetsExist() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Create a session, but do not pin it yet.
    let sessionId = "session-A"
    let session = manager.session(id: sessionId)

    // Ensure we're starting from a clean buffer state.
    _ = session.router.drainBufferedNotifications()

    let notification = try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/test",
            "params": ["value": 1],
        ],
        options: []
    )

    await yieldMessage(notification, to: upstream0)
    try await Task.sleep(nanoseconds: 50_000_000)

    let received = session.router.drainBufferedNotifications()
    #expect(received.isEmpty)
}

@Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let sessionId = "session-A"
    let session = manager.session(id: sessionId)
    _ = manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true)

    _ = session.router.drainBufferedNotifications()

    // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
    await yieldMessage(try makeToolListResponse(id: 9_999_999), to: upstream)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(session.router.drainBufferedNotifications().isEmpty)
}

@Test func sessionManagerReturnsNilWhenAllUpstreamsAreQuarantined() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    var config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    config.prewarmToolsList = true
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize primary upstream0.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    // Warm init -> upstream1.
    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    // Wait for per-upstream notifications/initialized.
    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Fail tools/list warmup on upstream0 to mark it unhealthy.
    var warmup0: Data?
    let warmupDeadline0 = Date().addingTimeInterval(2)
    while Date() < warmupDeadline0 {
        manager.refreshToolsListIfNeeded()
        if let req = (await upstream0.sent()).first(where: { methodName(from: $0) == "tools/list" }) {
            warmup0 = req
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(warmup0 != nil)
    if let warmup0 {
        let id = try extractUpstreamId(from: warmup0)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:], // invalid (no `tools` array) -> marks upstream unhealthy
        ]
        await upstream0.yield(.message(try JSONSerialization.data(withJSONObject: response, options: [])))
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    // Trigger another warmup; it should prefer upstream1 and fail there too so no healthy upstream exists.
    var warmup1: Data?
    let warmupDeadline1 = Date().addingTimeInterval(2)
    while Date() < warmupDeadline1 {
        manager.refreshToolsListIfNeeded()
        if let req = (await upstream1.sent()).first(where: { methodName(from: $0) == "tools/list" }) {
            warmup1 = req
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(warmup1 != nil)
    if let warmup1 {
        let id = try extractUpstreamId(from: warmup1)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ]
        await upstream1.yield(.message(try JSONSerialization.data(withJSONObject: response, options: [])))
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    let chosen = manager.chooseUpstreamIndex(sessionId: "session-A", shouldPin: true)
    #expect(chosen == nil)
}

@Test func sessionManagerRepinsAfterUpstreamExit() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    // Pin two sessions to different upstreams.
    let sessionIdA = "session-A"
    let sessionIdB = "session-B"
    _ = manager.session(id: sessionIdA)
    _ = manager.session(id: sessionIdB)

    let upstreamIndexA = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdA, shouldPin: true))
    let upstreamIndexB = try #require(manager.chooseUpstreamIndex(sessionId: sessionIdB, shouldPin: true))
    #expect(upstreamIndexA != upstreamIndexB)

    let pinnedTo1SessionId = upstreamIndexA == 1 ? sessionIdA : sessionIdB
    #expect(manager.chooseUpstreamIndex(sessionId: pinnedTo1SessionId, shouldPin: true) == 1)

    await upstream1.yield(.exit(1))
    try await Task.sleep(nanoseconds: 50_000_000)

    let repinned = try #require(manager.chooseUpstreamIndex(sessionId: pinnedTo1SessionId, shouldPin: true))
    #expect(repinned == 0)
}

@Test func sessionManagerRepinsWhenPinnedUpstreamIsQuarantinedByTimeouts() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = TestUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    let sessionId = "session-timeout-repin"
    _ = manager.session(id: sessionId)
    let pinned = try #require(manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true))

    manager.onRequestTimeout(sessionId: sessionId, requestIdKey: "dummy-1", upstreamIndex: pinned)
    manager.onRequestTimeout(sessionId: sessionId, requestIdKey: "dummy-2", upstreamIndex: pinned)
    manager.onRequestTimeout(sessionId: sessionId, requestIdKey: "dummy-3", upstreamIndex: pinned)

    let repinned = try #require(manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true))
    #expect(repinned != pinned)
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
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    await upstream0.yield(.message(try makeInitializeResponse(id: try extractUpstreamId(from: init0[0]))))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    await upstream1.yield(.message(try makeInitializeResponse(id: try extractUpstreamId(from: init1[0]))))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

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
    let upstreamIndexB = try #require(manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true))
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

@Test func sessionManagerReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = AlwaysOverloadedUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let sessionId = "session-overloaded"
    let session = manager.session(id: sessionId)
    let original = RPCId(any: NSNumber(value: 910))!
    let future = session.router.registerRequest(idKey: original.key, on: eventLoop, timeout: .seconds(1))
    let upstreamId = manager.assignUpstreamId(sessionId: sessionId, originalId: original, upstreamIndex: 0)
    manager.sendUpstream(try makeToolListRequest(id: upstreamId), upstreamIndex: 0)

    let response = try decodeJSON(from: try await future.get())
    let error = response["error"] as? [String: Any]
    #expect((error?["code"] as? NSNumber)?.intValue == -32002)
    #expect((error?["message"] as? String) == "upstream overloaded")
}

@Test func sessionManagerInitializeReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = AlwaysOverloadedUpstreamClient()
    let config = makeConfig(eagerInitialize: false, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream])

    let original = RPCId(any: NSNumber(value: 1001))!
    let future = manager.registerInitialize(
        originalId: original,
        requestObject: makeInitializeRequest(id: 1001),
        on: eventLoop
    )

    let response = try decodeJSON(from: try await future.get())
    let error = response["error"] as? [String: Any]
    #expect((error?["code"] as? NSNumber)?.intValue == -32002)
    #expect((error?["message"] as? String) == "upstream overloaded")
}

@Test func sessionManagerRepinsWhenPinnedUpstreamBecomesOverloaded() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream0 = ToggleableOverloadUpstreamClient()
    let upstream1 = TestUpstreamClient()
    let config = makeConfig(eagerInitialize: true, requestTimeout: 2)
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])

    // Initialize both upstreams.
    try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
    let init0 = await upstream0.sent()
    let init0Id = try extractUpstreamId(from: init0[0])
    await upstream0.yield(.message(try makeInitializeResponse(id: init0Id)))

    try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
    let init1 = await upstream1.sent()
    let init1Id = try extractUpstreamId(from: init1[0])
    await upstream1.yield(.message(try makeInitializeResponse(id: init1Id)))

    try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
    try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

    let sessionId = "session-overload-repin"
    let session = manager.session(id: sessionId)
    let pinned = try #require(manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true))
    #expect(pinned == 0)

    await upstream0.setOverloaded(true)

    let original = RPCId(any: NSNumber(value: 920))!
    let future = session.router.registerRequest(idKey: original.key, on: eventLoop, timeout: .seconds(1))
    let upstreamId = manager.assignUpstreamId(sessionId: sessionId, originalId: original, upstreamIndex: pinned)
    manager.sendUpstream(try makeToolListRequest(id: upstreamId), upstreamIndex: pinned)

    let response = try decodeJSON(from: try await future.get())
    let error = response["error"] as? [String: Any]
    #expect((error?["code"] as? NSNumber)?.intValue == -32002)
    #expect((error?["message"] as? String) == "upstream overloaded")

    let repinned = try #require(manager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: true))
    #expect(repinned == 1)

    let original2 = RPCId(any: NSNumber(value: 921))!
    let future2 = session.router.registerRequest(idKey: original2.key, on: eventLoop, timeout: .seconds(1))
    let upstreamId2 = manager.assignUpstreamId(sessionId: sessionId, originalId: original2, upstreamIndex: repinned)
    manager.sendUpstream(try makeToolListRequest(id: upstreamId2), upstreamIndex: repinned)
    await upstream1.yield(.message(try makeToolListResponse(id: upstreamId2)))
    _ = try await future2.get()
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
        eagerInitialize: eagerInitialize,
        prewarmToolsList: false
    )
}

private actor AlwaysOverloadedUpstreamClient: UpstreamClient {
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

    func send(_ data: Data) async -> UpstreamSendResult {
        _ = data
        return .overloaded
    }
}

private actor ToggleableOverloadUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private var sentMessages: [Data] = []
    private var overloaded = false

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

    func setOverloaded(_ value: Bool) {
        overloaded = value
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        sentMessages.append(data)
        return overloaded ? .overloaded : .accepted
    }

    func yield(_ event: UpstreamEvent) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        sentMessages
    }
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
    let actual = await upstream.sent().count
    throw WaitForSentCountError.timeout(expected: count, actual: actual)
}

private func waitForSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
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
    let actual = await upstream.sent().count
    throw WaitForSentCountError.timeout(expected: count, actual: actual)
}

private enum WaitForSentCountError: Error {
    case timeout(expected: Int, actual: Int)
}

private func waitForCondition(
    timeoutSeconds: UInt64,
    pollNanoseconds: UInt64 = 50_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    throw WaitForConditionError.timeout
}

private enum WaitForConditionError: Error {
    case timeout
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
