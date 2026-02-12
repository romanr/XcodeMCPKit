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
    private var terminatingProcess: Process?
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
        terminatingProcess = nil
        continuation.finish()
    }

    func requestRestart() async {
        guard !isStopping else { return }
        restartTask?.cancel()
        restartTask = nil

        // If we're already down (or never started), just start immediately.
        if process == nil {
            startLocked()
            return
        }

        logger.warning("Upstream restart requested")
        restartDelay = config.restartInitialDelay
        stopLocked()
        // The termination handler will emit an .exit event and schedule a restart.
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
                await self?.handleTermination(process: proc, status: proc.terminationStatus)
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
            terminatingProcess = process
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

        // If we're terminating an old process (e.g. via requestRestart) and a replacement process is
        // already running, suppress the exit event. Otherwise, SessionManager will treat this as an
        // upstream outage and clear pins/mappings for an upstream that is actually healthy.
        if wasTerminating, process != nil {
            logger.debug("Upstream process exited (superseded)", metadata: ["status": "\(status)"])
            return
        }

        logger.warning("Upstream process exited", metadata: ["status": "\(status)"])
        continuation.yield(.exit(status))
        // If a replacement process is already running, don't schedule another restart.
        if process == nil {
            scheduleRestart()
        }
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
