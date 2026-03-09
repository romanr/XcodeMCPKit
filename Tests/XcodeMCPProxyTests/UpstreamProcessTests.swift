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

@Test func upstreamProcessFlushesTrailingStderrLineWithoutNewline() async throws {
    let config = UpstreamProcess.Config(
        command: "/bin/sh",
        args: ["-c", "printf 'fatal stderr' >&2"],
        environment: ProcessInfo.processInfo.environment,
        restartInitialDelay: 1,
        restartMaxDelay: 1,
        maxQueuedWriteBytes: 1024
    )
    let upstream = UpstreamProcess(config: config)
    await upstream.start()
    defer {
        Task {
            await upstream.stop()
        }
    }

    let stderr = try await withTimeout(seconds: 2) {
        for await event in upstream.events {
            switch event {
            case .stderr(let message):
                return message
            case .message, .stdoutRecovery, .stdoutBufferSize, .exit:
                continue
            }
        }
        return ""
    }

    #expect(stderr == "fatal stderr")
}

@Test func upstreamProcessFlushesLargeStderrChunkWithoutWaitingForEOF() async throws {
    let config = UpstreamProcess.Config(
        command: "/bin/sh",
        args: ["-c", "head -c 20000 /dev/zero | tr '\\0' 'x' >&2; sleep 1"],
        environment: ProcessInfo.processInfo.environment,
        restartInitialDelay: 1,
        restartMaxDelay: 1,
        maxQueuedWriteBytes: 1024
    )
    let upstream = UpstreamProcess(config: config)
    await upstream.start()
    defer {
        Task {
            await upstream.stop()
        }
    }

    let stderr = try await withTimeout(seconds: 1) {
        for await event in upstream.events {
            switch event {
            case .stderr(let message):
                return message
            case .message, .stdoutRecovery, .stdoutBufferSize, .exit:
                continue
            }
        }
        return ""
    }

    #expect(stderr.contains("[truncated]"))
}

@Test func upstreamProcessEmitsBufferedStdoutResetWhenRestarting() async throws {
    let config = UpstreamProcess.Config(
        command: "/bin/cat",
        args: [],
        environment: ProcessInfo.processInfo.environment,
        restartInitialDelay: 1,
        restartMaxDelay: 1,
        maxQueuedWriteBytes: 1024
    )
    let upstream = UpstreamProcess(config: config)
    await upstream.start()
    defer {
        Task {
            await upstream.stop()
        }
    }

    let observedSizes = Task { () -> [Int] in
        var sizes: [Int] = []
        for await event in upstream.events {
            switch event {
            case .stdoutBufferSize(let size):
                sizes.append(size)
                if sizes.contains(where: { $0 > 0 }), sizes.contains(0) {
                    return sizes
                }
            case .message, .stderr, .stdoutRecovery, .exit:
                continue
            }
        }
        return sizes
    }

    let sendResult = await upstream.send(Data("{".utf8))
    switch sendResult {
    case .accepted:
        break
    case .overloaded:
        Issue.record("send should not overload while checking buffered stdout reset")
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    await upstream.requestRestart()

    let sizes = try await withTimeout(seconds: 2) {
        await observedSizes.value
    }

    #expect(sizes.contains(where: { $0 > 0 }))
    #expect(sizes.contains(0))
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
