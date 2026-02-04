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
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstream: upstream)

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
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstream: upstream)

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
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstream: upstream)
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
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstream: upstream)

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
