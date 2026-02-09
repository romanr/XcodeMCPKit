import Foundation
import Logging

actor UpstreamProcess: UpstreamClient {
    struct Config {
        var command: String
        var args: [String]
        var environment: [String: String]
        var restartInitialDelay: TimeInterval
        var restartMaxDelay: TimeInterval
    }

    typealias Event = UpstreamEvent

    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation

    private let config: Config
    private var process: Process?
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var restartDelay: TimeInterval
    private var framer = StdioFramer()
    private var isStopping = false
    private var restartTask: Task<Void, Never>?
    private let logger: Logger = ProxyLogging.make("upstream")

    init(config: Config) {
        self.config = config
        self.restartDelay = config.restartInitialDelay
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {
        isStopping = false
        startLocked()
    }

    func stop() async {
        isStopping = true
        restartTask?.cancel()
        restartTask = nil
        stopLocked()
        continuation.finish()
    }

    func send(_ data: Data) async {
        if process == nil {
            startLocked()
        }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        stdinPipe.fileHandleForWriting.write(payload)
    }

    private func startLocked() {
        guard process == nil else { return }

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        framer = StdioFramer()

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
                return
            }
            Task { [weak self] in
                await self?.handleStderrData(data)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            restartDelay = config.restartInitialDelay
        } catch {
            logger.error("Failed to start upstream process", metadata: ["error": "\(error)"])
            scheduleRestart()
        }
    }

    private func stopLocked() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let process = process {
            process.terminate()
        }
        process = nil
    }

    private func handleStdoutData(_ data: Data) {
        let messages = framer.append(data)
        for message in messages {
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
    }

    private func isValidJSONPayload(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return json is [String: Any] || json is [Any]
    }

    private func handleTermination(status: Int32) {
        process = nil
        guard !isStopping else {
            return
        }
        logger.warning("Upstream process exited", metadata: ["status": "\(status)"])
        continuation.yield(.exit(status))
        scheduleRestart()
    }

    private func handleStderrData(_ data: Data) {
        if let message = String(data: data, encoding: .utf8) {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            logger.error("Upstream stderr: \(trimmed)")
        } else {
            logger.error("Upstream stderr (binary)", metadata: ["bytes": "\(data.count)"])
        }
    }

    private func scheduleRestart() {
        guard !isStopping else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, config.restartMaxDelay)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            let nanos = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.start()
        }
    }

    private func resolveCommand(command: String, args: [String]) -> (URL, [String]) {
        if command.contains("/") {
            return (URL(fileURLWithPath: command), args)
        }
        let env = "/usr/bin/env"
        return (URL(fileURLWithPath: env), [command] + args)
    }
}
