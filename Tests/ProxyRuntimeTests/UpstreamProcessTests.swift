import Foundation
import Testing
import XcodeMCPTestSupport

@testable import ProxyRuntime

@Suite(.serialized)
struct UpstreamProcessTests {
    @Test func upstreamProcessSendRemainsResponsiveUnderStdinBackpressure() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/cat",
            args: [],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 550_000
        )
        try await withUpstreamProcess(config: config) { upstream in
            let payload = Data(repeating: 0x41, count: 500_000)
            let first = try await waitWithTimeout(
                "first send should complete before backpressure timeout",
                timeout: .seconds(5)
            ) {
                await upstream.send(payload)
            }
            switch first {
            case .accepted:
                break
            case .overloaded:
                Issue.record("first send should be accepted before queue reaches limit")
            }

            let second = try await waitWithTimeout(
                "second send should return promptly under backpressure",
                timeout: .seconds(5)
            ) {
                await upstream.send(payload)
            }
            switch second {
            case .accepted:
                break
            case .overloaded:
                break
            }
        }
    }

    @Test func upstreamProcessFlushesTrailingStderrLineWithoutNewline() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "printf 'fatal stderr' >&2"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamProcess(config: config) { upstream in
            let stderr = try await waitWithTimeout(
                "stderr line should be flushed without newline",
                timeout: .seconds(2)
            ) {
                for await event in upstream.events {
                    switch event {
                    case .stderr(let message):
                        return message
                    case .message, .stdoutProtocolViolation, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return ""
            }

            #expect(stderr == "fatal stderr")
        }
    }

    @Test func upstreamProcessFlushesLargeStderrChunkWithoutWaitingForEOF() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "head -c 20000 /dev/zero | tr '\\0' 'x' >&2; sleep 1"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamProcess(config: config) { upstream in
            let stderr = try await waitWithTimeout(
                "large stderr chunk should flush before EOF",
                timeout: .seconds(1)
            ) {
                for await event in upstream.events {
                    switch event {
                    case .stderr(let message):
                        return message
                    case .message, .stdoutProtocolViolation, .stdoutBufferSize, .exit:
                        continue
                    }
                }
                return ""
            }

            #expect(stderr.contains("[truncated]"))
        }
    }

    @Test func upstreamProcessEmitsBufferedStdoutResetWhenStopping() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/cat",
            args: [],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        let upstream = UpstreamProcess(config: config)
        await upstream.start()
        defer {
            Task {
                await upstream.stop()
            }
        }

        let observedSizesRecorder = RecordedValues<Int>()
        let observedSizes = Task { () -> [Int] in
            var sizes: [Int] = []
            for await event in upstream.events {
                switch event {
                case .stdoutBufferSize(let size):
                    sizes.append(size)
                    await observedSizesRecorder.append(size)
                    if sizes.contains(where: { $0 > 0 }), sizes.contains(0) {
                        return sizes
                    }
                case .message, .stderr, .stdoutProtocolViolation, .exit:
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

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                await observedSizesRecorder.snapshot().contains(where: { $0 > 0 })
            }
        )
        await upstream.stop()

        let sizes = try await waitWithTimeout(
            "buffered stdout should reset to zero after stop",
            timeout: .seconds(2)
        ) {
            await observedSizes.value
        }

        #expect(sizes.contains(where: { $0 > 0 }))
        #expect(sizes.contains(0))
    }

    @Test func upstreamProcessTreatsInvalidStdoutAsFatalProtocolViolation() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: ["-c", "printf 'Content-Length: abc\\r\\n\\r\\n{}'; sleep 5"],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )
        try await withUpstreamProcess(config: config) { upstream in
        let events = try await waitWithTimeout(
                "invalid stdout should emit a protocol violation without auto-restart",
                timeout: .seconds(3)
            ) {
                var sawViolation = false
                var bufferedSizes: [Int] = []

                for await event in upstream.events {
                    switch event {
                    case .stdoutProtocolViolation(let violation):
                        sawViolation = true
                        #expect(violation.reason == .invalidContentLengthHeader)
                    case .stdoutBufferSize(let size):
                        bufferedSizes.append(size)
                    case .message, .stderr, .exit:
                        continue
                    }

                    if sawViolation {
                        return bufferedSizes
                    }
                }

                return bufferedSizes
            }

            #expect(events.contains(where: { $0 > 0 }))
        }
    }
}

private func withUpstreamProcess<T: Sendable>(
    config: UpstreamProcess.Config,
    _ body: @escaping @Sendable (UpstreamProcess) async throws -> T
) async throws -> T {
    let upstream = UpstreamProcess(config: config)
    await upstream.start()
    do {
        let result = try await body(upstream)
        await upstream.stop()
        return result
    } catch {
        await upstream.stop()
        throw error
    }
}
