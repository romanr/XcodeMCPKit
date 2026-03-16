import Foundation
import Darwin
import Logging
import ProxyCore

package actor UpstreamProcess: UpstreamClient {
    package struct Config {
        package var command: String
        package var args: [String]
        package var environment: [String: String]
        package var maxQueuedWriteBytes: Int

        package init(
            command: String,
            args: [String],
            environment: [String: String],
            maxQueuedWriteBytes: Int
        ) {
            self.command = command
            self.args = args
            self.environment = environment
            self.maxQueuedWriteBytes = maxQueuedWriteBytes
        }
    }

    typealias Event = UpstreamEvent

    package nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation

    private let config: Config
    private var process: Process?
    private var terminatingProcess: Process?
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var framer = StdioFramer()
    private var isStopping = false
    private var queuedWriteBytes = 0
    private var writeGeneration: UInt64 = 0
    private var stderrBuffer = ""
    private var lastReportedBufferedStdoutBytes = 0
    private let writeQueue = DispatchQueue(label: "XcodeMCPProxy.UpstreamProcess.write")
    private let logger: Logger = ProxyLogging.make("upstream")
    private let maxBufferedStderrBytes = 16 * 1024

    package init(config: Config) {
        self.config = config
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    package func start() async {
        isStopping = false
        startLocked()
    }

    package func stop() async {
        isStopping = true
        stopLocked()
        terminatingProcess = nil
        continuation.finish()
    }

    package func send(_ data: Data) async -> UpstreamSendResult {
        if process == nil {
            startLocked()
        }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        if queuedWriteBytes + payload.count > config.maxQueuedWriteBytes {
            logger.warning(
                "Upstream write queue overloaded",
                metadata: [
                    "queued_bytes": "\(queuedWriteBytes)",
                    "payload_bytes": "\(payload.count)",
                    "limit_bytes": "\(config.maxQueuedWriteBytes)",
                ]
            )
            return .overloaded
        }

        let queuedPayload = payload
        let queuedPayloadBytes = queuedPayload.count
        queuedWriteBytes += queuedPayloadBytes
        let handle = stdinPipe.fileHandleForWriting
        let generation = writeGeneration
        writeQueue.async { [weak self] in
            var writeError: Error?
            do {
                try handle.write(contentsOf: queuedPayload)
            } catch {
                writeError = error
            }
            Task { [weak self] in
                await self?.completeQueuedWrite(
                    bytes: queuedPayloadBytes,
                    generation: generation,
                    error: writeError
                )
            }
        }
        return .accepted
    }

    private func startLocked() {
        guard process == nil else { return }

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        configureNoSigPipe(on: stdinPipe.fileHandleForWriting)
        framer = StdioFramer()
        queuedWriteBytes = 0
        writeGeneration &+= 1
        stderrBuffer = ""
        resetBufferedStdoutBytesIfNeeded()

        let (executableURL, args) = resolveCommand(command: config.command, args: config.args)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.environment = config.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            Task {
                await self?.handleStdoutData(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                Task { [weak self] in
                    await self?.handleStderrEOF()
                }
                return
            }
            Task { [weak self] in
                await self?.handleStderrData(data)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleTermination(process: proc, status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            logger.error("Failed to start upstream process", metadata: ["error": "\(error)"])
        }
    }

    private func stopLocked() {
        flushBufferedStderrIfNeeded()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        queuedWriteBytes = 0
        writeGeneration &+= 1
        stderrBuffer = ""
        resetBufferedStdoutBytesIfNeeded()
        if let process = process {
            terminatingProcess = process
            process.terminate()
        }
        process = nil
    }

    private func handleStdoutData(_ data: Data) {
        let result = framer.append(data)
        for message in result.messages {
            guard isValidJSONPayload(message) else {
                if let text = String(data: message, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let preview = String(trimmed.prefix(200))
                        logger.warning("Dropping non-JSON upstream stdout", metadata: ["preview": "\(preview)"])
                    }
                } else {
                    logger.warning("Dropping non-UTF8 upstream stdout", metadata: ["bytes": "\(message.count)"])
                }
                continue
            }
            continuation.yield(.message(message))
        }

        if lastReportedBufferedStdoutBytes != result.bufferedByteCount {
            lastReportedBufferedStdoutBytes = result.bufferedByteCount
            continuation.yield(.stdoutBufferSize(result.bufferedByteCount))
        }

        guard let protocolViolation = result.protocolViolation else {
            return
        }

        logger.error(
            "Fatal upstream stdout protocol violation",
            metadata: [
                "reason": .string(protocolViolation.reason.rawValue),
                "buffered_bytes": .string("\(protocolViolation.bufferedByteCount)"),
                "preview": .string(protocolViolation.preview),
            ]
        )
        continuation.yield(.stdoutProtocolViolation(protocolViolation))
    }

    private func resetBufferedStdoutBytesIfNeeded() {
        guard lastReportedBufferedStdoutBytes != 0 else { return }
        lastReportedBufferedStdoutBytes = 0
        continuation.yield(.stdoutBufferSize(0))
    }

    private func handleTermination(process terminated: Process, status: Int32) {
        let wasCurrent = process.map { terminated === $0 } ?? false
        let wasTerminating = terminatingProcess.map { terminated === $0 } ?? false

        if wasCurrent {
            process = nil
        } else if wasTerminating {
            terminatingProcess = nil
        } else {
            // Stale termination for an older process we no longer track.
            return
        }

        guard !isStopping else {
            return
        }

        if wasTerminating, process != nil {
            logger.debug("Upstream process exited (superseded)", metadata: ["status": "\(status)"])
            return
        }

        logger.warning("Upstream process exited", metadata: ["status": "\(status)"])
        continuation.yield(.exit(status))
    }

    private func handleStderrData(_ data: Data) {
        if let message = String(data: data, encoding: .utf8) {
            stderrBuffer.append(message)
            let parts = stderrBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            let completeLines = parts.dropLast()
            stderrBuffer = parts.last.map(String.init) ?? ""

            for line in completeLines {
                emitStderrLine(String(line))
            }
            flushBufferedStderrChunkIfNeeded()
        } else {
            logger.error("Upstream stderr (binary)", metadata: ["bytes": "\(data.count)"])
        }
    }

    private func handleStderrEOF() {
        flushBufferedStderrIfNeeded()
    }

    private func flushBufferedStderrIfNeeded() {
        emitStderrLine(stderrBuffer)
        stderrBuffer = ""
    }

    private func flushBufferedStderrChunkIfNeeded() {
        while stderrBuffer.utf8.count > maxBufferedStderrBytes {
            let prefixData = Data(stderrBuffer.utf8.prefix(maxBufferedStderrBytes))
            emitStderrLine(String(decoding: prefixData, as: UTF8.self), suffix: " [truncated]")
            stderrBuffer = String(decoding: stderrBuffer.utf8.dropFirst(maxBufferedStderrBytes), as: UTF8.self)
        }
    }

    private func emitStderrLine(_ line: String, suffix: String = "") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = suffix.isEmpty ? trimmed : trimmed + suffix
        logger.error("Upstream stderr: \(message)")
        continuation.yield(.stderr(message))
    }

    private func resolveCommand(command: String, args: [String]) -> (URL, [String]) {
        if command.contains("/") {
            return (URL(fileURLWithPath: command), args)
        }
        let env = "/usr/bin/env"
        return (URL(fileURLWithPath: env), [command] + args)
    }

    private func configureNoSigPipe(on handle: FileHandle) {
        let fd = handle.fileDescriptor
        let result = fcntl(fd, F_SETNOSIGPIPE, 1)
        if result == -1 {
            logger.warning(
                "Failed to disable SIGPIPE on upstream stdin pipe",
                metadata: ["errno": "\(errno)"]
            )
        }
    }

    private func completeQueuedWrite(
        bytes: Int,
        generation: UInt64,
        error: Error?
    ) {
        if generation == writeGeneration {
            queuedWriteBytes = max(0, queuedWriteBytes - bytes)
        }
        guard let error else { return }
        logger.warning("Upstream async write failed", metadata: ["error": "\(error)"])
    }
}
