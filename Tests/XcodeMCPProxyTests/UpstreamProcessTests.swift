import Foundation
import Testing
@testable import XcodeMCPProxy

@Test func upstreamProcessSendRemainsResponsiveUnderStdinBackpressure() async throws {
    let config = UpstreamProcess.Config(
        command: "/bin/cat",
        args: [],
        environment: ProcessInfo.processInfo.environment,
        restartInitialDelay: 1,
        restartMaxDelay: 1,
        maxQueuedWriteBytes: 550_000
    )
    let upstream = UpstreamProcess(config: config)
    await upstream.start()
    defer {
        Task {
            await upstream.stop()
        }
    }

    let payload = Data(repeating: 0x41, count: 500_000)
    let first = try await withTimeout(seconds: 2) {
        await upstream.send(payload)
    }
    switch first {
    case .accepted:
        break
    case .overloaded:
        Issue.record("first send should be accepted before queue reaches limit")
    }

    let second = try await withTimeout(seconds: 2) {
        await upstream.send(payload)
    }
    switch second {
    case .accepted:
        break
    case .overloaded:
        break
    }

    // Give the async writer a moment to drain before teardown.
    try await Task.sleep(nanoseconds: 100_000_000)
}

private enum UpstreamProcessTestTimeoutError: Error {
    case timedOut(seconds: UInt64)
}

private func withTimeout<T: Sendable>(
    seconds: UInt64,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw UpstreamProcessTestTimeoutError.timedOut(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw UpstreamProcessTestTimeoutError.timedOut(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
