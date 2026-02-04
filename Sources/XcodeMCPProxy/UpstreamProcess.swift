import Foundation

final class UpstreamProcess: @unchecked Sendable {
    struct Config {
        var command: String
        var args: [String]
        var environment: [String: String]
        var restartInitialDelay: TimeInterval
        var restartMaxDelay: TimeInterval
    }

    private let config: Config
    private let queue = DispatchQueue(label: "XcodeMCPProxy.UpstreamProcess")
    private var process: Process?
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var restartDelay: TimeInterval
    private var framer = StdioFramer()

    var onMessage: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(config: Config) {
        self.config = config
        self.restartDelay = config.restartInitialDelay
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            self?.sendLocked(data)
        }
    }

    private func startLocked() {
        guard process == nil else { return }

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

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
            self?.handleStdoutData(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(status: proc.terminationStatus)
        }

        do {
            try process.run()
            self.process = process
            restartDelay = config.restartInitialDelay
        } catch {
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

    private func sendLocked(_ data: Data) {
        if process == nil {
            startLocked()
        }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        stdinPipe.fileHandleForWriting.write(payload)
    }

    private func handleStdoutData(_ data: Data) {
        let messages = framer.append(data)
        for message in messages {
            onMessage?(message)
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        onExit?(status)
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, config.restartMaxDelay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startLocked()
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
