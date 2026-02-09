import Darwin
import Foundation
import XcodeMCPProxy

private struct ServerOptions {
    var forwardedArgs: [String]
    var hasListenFlag: Bool
    var hasHostFlag: Bool
    var hasPortFlag: Bool
    var hasXcodePidFlag: Bool
    var hasLazyInitFlag: Bool
    var forceRestart: Bool
    var dryRun: Bool
}

private enum ServerError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

@main
struct XcodeMCPProxyServer {
    static func main() async {
        ProxyLogging.bootstrap()

        do {
            let environment = ProcessInfo.processInfo.environment
            var options = try parseOptions(
                args: CommandLine.arguments,
                environment: environment
            )
            applyDefaults(from: environment, to: &options)

            let isDryRun = options.dryRun || isTruthy(environment["DRY_RUN"])
            if isDryRun {
                let command = (["xcode-mcp-proxy-server"] + options.forwardedArgs).joined(separator: " ")
                print(command)
                return
            }

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            if options.forceRestart, config.listenPort > 0 {
                _ = terminateExistingProxyServerIfNeeded(
                    host: config.listenHost,
                    port: config.listenPort
                )
            }

            do {
                let server = ProxyServer(config: config)
                _ = try server.startAndWriteDiscovery()
                try await server.wait()
            } catch {
                if config.listenPort > 0, isAddressAlreadyInUse(error) {
                    writePortInUseError(host: config.listenHost, port: config.listenPort)
                    exit(1)
                }
                throw error
            }
        } catch let error as ServerError {
            writeError("error: \(error.description)")
            writeError("run with --help for usage")
            exit(1)
        } catch let error as CLIError {
            writeError("\(error.description)")
            writeError(serverUsage())
            exit(1)
        } catch {
            writeError("error: \(error)")
            exit(1)
        }
    }
}

private func parseOptions(args: [String], environment: [String: String]) throws -> ServerOptions {
    var forwarded: [String] = []
    var hasListen = false
    var hasHost = false
    var hasPort = false
    var hasXcodePid = false
    var hasLazyInit = false
    var forceRestart = false
    var dryRun = false

    let valueFlags: Set<String> = [
        "--listen",
        "--host",
        "--port",
        "--upstream-command",
        "--upstream-args",
        "--upstream-arg",
        "--upstream-processes",
        "--xcode-pid",
        "--session-id",
        "--max-body-bytes",
        "--request-timeout",
    ]

    var index = 1
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--dry-run":
            dryRun = true
            index += 1
            continue
        case "--force-restart":
            forceRestart = true
            index += 1
            continue
        case "--stdio":
            throw ServerError.message("--stdio is not supported in server mode (use xcode-mcp-proxy)")
        case "--url":
            throw ServerError.message("--url is not supported in server mode (use xcode-mcp-proxy)")
        case "--lazy-init":
            hasLazyInit = true
            forwarded.append(arg)
            index += 1
            continue
        case "--listen":
            hasListen = true
        case "--host":
            hasHost = true
        case "--port":
            hasPort = true
        case "--xcode-pid":
            hasXcodePid = true
        default:
            break
        }

        forwarded.append(arg)
        if valueFlags.contains(arg) {
            guard index + 1 < args.count else {
                throw ServerError.message("\(arg) requires a value")
            }
            forwarded.append(args[index + 1])
            index += 2
        } else {
            index += 1
        }
    }

    return ServerOptions(
        forwardedArgs: forwarded,
        hasListenFlag: hasListen,
        hasHostFlag: hasHost,
        hasPortFlag: hasPort,
        hasXcodePidFlag: hasXcodePid,
        hasLazyInitFlag: hasLazyInit,
        forceRestart: forceRestart,
        dryRun: dryRun
    )
}

private func applyDefaults(from environment: [String: String], to options: inout ServerOptions) {
    if !options.hasListenFlag && !options.hasHostFlag && !options.hasPortFlag {
        if let listen = nonEmpty(environment["LISTEN"]) {
            options.forwardedArgs += ["--listen", listen]
        } else {
            let envHost = nonEmpty(environment["HOST"])
            let envPort = nonEmpty(environment["PORT"])
            if envHost != nil || envPort != nil {
                let host = envHost ?? "localhost"
                let port = envPort ?? "8765"
                options.forwardedArgs += ["--listen", "\(host):\(port)"]
            } else {
                options.forwardedArgs += ["--listen", "localhost:8765"]
            }
        }
    }
    if !options.hasListenFlag, options.hasHostFlag, !options.hasPortFlag {
        // Keep the default port when only --host is specified.
        options.forwardedArgs += ["--port", "8765"]
    }

    if !options.hasXcodePidFlag {
        if let explicit = nonEmpty(environment["XCODE_PID"]) ?? nonEmpty(environment["MCP_XCODE_PID"]) {
            options.forwardedArgs += ["--xcode-pid", explicit]
        } else if let resolved = resolveXcodePid() {
            options.forwardedArgs += ["--xcode-pid", resolved]
        } else {
            writeError("warning: Xcode PID not found; running without --xcode-pid.")
        }
    }

    if !options.hasLazyInitFlag, isTruthy(environment["LAZY_INIT"]) {
        options.forwardedArgs.append("--lazy-init")
    }
}

private func resolveXcodePid() -> String? {
    if let pid = firstLine(runCommand("/usr/bin/pgrep", ["-x", "Xcode"])) {
        return pid
    }
    if let pid = firstLine(runCommand("/usr/bin/pgrep", ["-f", "/Applications/Xcode.*\\.app/Contents/MacOS/Xcode"])) {
        return pid
    }
    if let pid = firstLine(runCommand("/usr/bin/pgrep", ["-f", "Xcode.app/Contents/MacOS/Xcode"])) {
        return pid
    }

    _ = runCommand("/usr/bin/open", ["-a", "Xcode"])
    for _ in 0..<40 {
        if let pid = firstLine(runCommand("/usr/bin/pgrep", ["-x", "Xcode"])) {
            return pid
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return nil
}

private func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

private func firstLine(_ output: String?) -> String? {
    guard let output else { return nil }
    return output.split(whereSeparator: \.isNewline).first.map { String($0) }
}

private func printUsage() {
    print(serverUsage())
}

private func serverUsage() -> String {
    """
    Usage:
      xcode-mcp-proxy-server [options]

    Options:
      --listen host:port
      --host host
      --port port
      --upstream-processes n
      --xcode-pid pid
      --lazy-init
      --force-restart
      --dry-run
      -h, --help

    Notes:
      - Starts the HTTP/SSE proxy server (and spawns xcrun mcpbridge as upstream processes).
      - Use xcode-mcp-proxy as a STDIO adapter for Codex / Claude Code.
      - Default listen: localhost:8765 (override via --listen / --host / --port or env LISTEN/HOST/PORT).
      - Xcode PID is detected automatically when not specified.
      - When the listen port is already in use, rerun with --force-restart to terminate an existing xcode-mcp-proxy-server.
    """
}

private func writeError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    return raw
}

private func isTruthy(_ value: String?) -> Bool {
    guard let raw = nonEmpty(value) else { return false }
    return ["1", "true", "yes", "on"].contains(raw.lowercased())
}

private func isAddressAlreadyInUse(_ error: Error) -> Bool {
    // NIO errors include the errno value in their string representation (e.g. "(errno: 48)").
    // We avoid importing NIO here to keep the server target lightweight.
    let text = String(describing: error)
    if text.localizedCaseInsensitiveContains("Address already in use") {
        return true
    }
    return text.contains("errno: \(EADDRINUSE)")
}

private func writePortInUseError(host: String, port: Int) {
    let pids = detectExistingProxyServerPIDs(port: port)

    let displayHost: String = {
        // Avoid `::1:8765` ambiguity by bracketing IPv6 literals.
        if host.contains(":"), !host.hasPrefix("[") {
            return "[\(host)]"
        }
        return host
    }()

    var lines: [String] = []
    lines.reserveCapacity(8)
    lines.append("error: listen \(displayHost):\(port) は既に使用中です（Address already in use）。")
    if pids.count == 1 {
        lines.append("起動中の xcode-mcp-proxy-server を検出しました (pid: \(pids[0])).")
    } else if pids.count > 1 {
        let formatted = pids.map(String.init).joined(separator: ", ")
        lines.append("起動中の xcode-mcp-proxy-server を検出しました (pids: \(formatted)).")
    }
    lines.append("既存プロセスを終了してから再実行してください。")
    lines.append("強制再開始する場合は `--force-restart` を付けて再実行すると、既存の xcode-mcp-proxy-server を終了して起動し直します。")
    lines.append("")
    lines.append("例:")
    lines.append("  pkill -x xcode-mcp-proxy-server")
    lines.append("  xcode-mcp-proxy-server --force-restart")

    writeError(lines.joined(separator: "\n"))
}

@discardableResult
private func terminateExistingProxyServerIfNeeded(host: String, port: Int) -> Bool {
    // Prefer the discovery record (only present when the listener is our own proxy server).
    if let record = Discovery.read(), record.port == port {
        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        if record.pid != currentPID, isProxyServerProcess(pid: record.pid) {
            writeError("warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(record.pid)); terminating it.")
            if terminate(pid: record.pid) {
                waitForPortToBeFree(port: port, timeout: 2.0)
                return true
            }
        }
    }

    // Fallback: detect listeners on the port (only terminate our own proxy server process).
    let pids = listeningPIDs(onTCPPort: port)
    guard !pids.isEmpty else { return false }

    let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
    var didTerminate = false
    for pid in pids where pid != currentPID {
        guard isProxyServerProcess(pid: pid) else { continue }
        writeError("warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(pid)); terminating it.")
        if terminate(pid: pid) {
            didTerminate = true
        }
    }
    if didTerminate {
        waitForPortToBeFree(port: port, timeout: 2.0)
    }
    return didTerminate
}

private func detectExistingProxyServerPIDs(port: Int) -> [Int] {
    var pids: [Int] = []
    pids.reserveCapacity(4)

    if let record = Discovery.read(), record.port == port {
        if isProxyServerProcess(pid: record.pid) {
            pids.append(record.pid)
        }
    }

    for pid in listeningPIDs(onTCPPort: port) where isProxyServerProcess(pid: pid) {
        pids.append(pid)
    }

    // Keep order stable while removing duplicates.
    var seen = Set<Int>()
    return pids.filter { seen.insert($0).inserted }
}

private func isProxyServerProcess(pid: Int) -> Bool {
    guard pid > 0 else { return false }
    guard let comm = firstLine(runCommand("/bin/ps", ["-p", "\(pid)", "-o", "comm="]))?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !comm.isEmpty else {
        return false
    }
    // `comm` may be just the executable name, or a (possibly relative) path.
    let name = URL(fileURLWithPath: comm).lastPathComponent
    return name == "xcode-mcp-proxy-server"
}

private func listeningPIDs(onTCPPort port: Int) -> [Int] {
    // macOS: lsof lives in /usr/sbin. If it fails, return empty and let the bind error surface.
    guard let output = runCommand("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) else {
        return []
    }
    let lines = output.split(whereSeparator: \.isNewline)
    return lines.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func terminate(pid: Int) -> Bool {
    guard pid > 0 else { return false }
    if !isProcessAlive(pid) {
        return true
    }

    let termResult = kill(pid_t(pid), SIGTERM)
    if termResult != 0, errno != ESRCH {
        return false
    }
    if waitForProcessExit(pid: pid, timeout: 1.0) {
        return true
    }

    let killResult = kill(pid_t(pid), SIGKILL)
    if killResult != 0, errno != ESRCH {
        return false
    }
    return waitForProcessExit(pid: pid, timeout: 1.0)
}

private func isProcessAlive(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    let result = kill(pid_t(pid), 0)
    if result == 0 {
        return true
    }
    return errno == EPERM
}

private func waitForProcessExit(pid: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !isProcessAlive(pid) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return !isProcessAlive(pid)
}

private func waitForPortToBeFree(port: Int, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if listeningPIDs(onTCPPort: port).isEmpty {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}
