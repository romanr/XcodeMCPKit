import Foundation
import NIO
import Testing
@testable import XcodeMCPProxy

@Test func proxyRouterMatchesId() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }

    let router = ProxyRouter(
        requestTimeout: .seconds(5),
        hasActiveSSE: { false },
        sendNotification: { _ in }
    )

    let future = router.registerRequest(idKey: "1", on: group.next())
    let response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
    router.handleIncoming(Data(response.utf8))

    let buffer = try await future.get()
    let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
    #expect(string == response)
}

@Test func proxyRouterBuffersNotifications() async throws {
    let router = ProxyRouter(
        requestTimeout: .seconds(5),
        hasActiveSSE: { false },
        sendNotification: { _ in }
    )

    let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
    router.handleIncoming(Data(notification.utf8))

    let buffered = router.drainBufferedNotifications()
    #expect(buffered.count == 1)
    #expect(String(data: buffered[0], encoding: .utf8) == notification)
}

@Test func proxyRouterSendsNotifications() async throws {
    var received: [String] = []
    let router = ProxyRouter(
        requestTimeout: .seconds(5),
        hasActiveSSE: { true },
        sendNotification: { data in
            received.append(String(decoding: data, as: UTF8.self))
        }
    )

    let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
    router.handleIncoming(Data(notification.utf8))
    #expect(received == [notification])
}

private func shutdown(_ group: EventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}
