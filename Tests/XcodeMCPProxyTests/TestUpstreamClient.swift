import Foundation
@testable import XcodeMCPProxy

actor TestUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private var sentMessages: [Data] = []
    private var startCountValue = 0
    private var stopCountValue = 0

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {
        startCountValue += 1
    }

    func stop() async {
        stopCountValue += 1
        continuation.finish()
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        sentMessages.append(data)
        return .accepted
    }

    func yield(_ event: UpstreamEvent) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        sentMessages
    }

    func startCount() async -> Int {
        startCountValue
    }

    func stopCount() async -> Int {
        stopCountValue
    }
}
