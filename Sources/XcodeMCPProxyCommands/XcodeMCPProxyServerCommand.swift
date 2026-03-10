import Darwin
import Foundation
import XcodeMCPProxy

extension ProxyServer: ProxyServerCommandServer {}

package struct ProxyServerOptions {
    package var forwardedArgs: [String]
    package var showHelp: Bool
    package var hasListenFlag: Bool
    package var hasHostFlag: Bool
    package var hasPortFlag: Bool
    package var hasXcodePidFlag: Bool
    package var hasLazyInitFlag: Bool
    package var forceRestart: Bool
    package var dryRun: Bool

    package init(
        forwardedArgs: [String],
        showHelp: Bool,
        hasListenFlag: Bool,
        hasHostFlag: Bool,
        hasPortFlag: Bool,
        hasXcodePidFlag: Bool,
        hasLazyInitFlag: Bool,
        forceRestart: Bool,
        dryRun: Bool
    ) {
        self.forwardedArgs = forwardedArgs
        self.showHelp = showHelp
        self.hasListenFlag = hasListenFlag
        self.hasHostFlag = hasHostFlag
        self.hasPortFlag = hasPortFlag
        self.hasXcodePidFlag = hasXcodePidFlag
        self.hasLazyInitFlag = hasLazyInitFlag
        self.forceRestart = forceRestart
        self.dryRun = dryRun
    }
}

package enum ProxyServerCommandError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct XcodeMCPProxyServerCommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var resolveXcodePid: () -> String?
        package var terminateExistingServer: (String, Int) -> Bool
        package var makeServer: (ProxyConfig) -> any ProxyServerCommandServer
        package var isAddressAlreadyInUse: (Error) -> Bool
        package var detectExistingProxyServerPIDs: (String, Int) -> [Int]

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            resolveXcodePid: @escaping () -> String?,
            terminateExistingServer: @escaping (String, Int) -> Bool,
            makeServer: @escaping (ProxyConfig) -> any ProxyServerCommandServer,
            isAddressAlreadyInUse: @escaping (Error) -> Bool,
            detectExistingProxyServerPIDs: @escaping (String, Int) -> [Int]
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.resolveXcodePid = resolveXcodePid
            self.terminateExistingServer = terminateExistingServer
            self.makeServer = makeServer
            self.isAddressAlreadyInUse = isAddressAlreadyInUse
            self.detectExistingProxyServerPIDs = detectExistingProxyServerPIDs
        }

        package static var live: Self {
            Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                resolveXcodePid: XcodeMCPProxyServerCommand.resolveXcodePid,
                terminateExistingServer: XcodeMCPProxyServerCommand.terminateExistingProxyServerIfNeeded,
                makeServer: { ProxyServer(config: $0) },
                isAddressAlreadyInUse: XcodeMCPProxyServerCommand.isAddressAlreadyInUse,
                detectExistingProxyServerPIDs: XcodeMCPProxyServerCommand.detectExistingProxyServerPIDs
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)

        do {
            var options = try Self.parseOptions(args: args)
            if options.showHelp {
                dependencies.stdout(Self.serverUsage())
                return 0
            }
            Self.applyDefaults(
                from: environment,
                to: &options,
                resolveXcodePid: dependencies.resolveXcodePid,
                stderr: dependencies.stderr
            )

            let isDryRun = options.dryRun || Self.isTruthy(environment["DRY_RUN"])
            if isDryRun {
                let command = (["xcode-mcp-proxy-server"] + options.forwardedArgs)
                    .joined(separator: " ")
                dependencies.stdout(command)
                return 0
            }

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            if options.forceRestart, config.listenPort > 0 {
                _ = dependencies.terminateExistingServer(config.listenHost, config.listenPort)
            }

            do {
                let server = dependencies.makeServer(config)
                _ = try server.startAndWriteDiscovery()
                try await server.wait()
                return 0
            } catch {
                if config.listenPort > 0, dependencies.isAddressAlreadyInUse(error) {
                    let message = Self.portInUseMessage(
                        host: config.listenHost,
                        port: config.listenPort,
                        pids: dependencies.detectExistingProxyServerPIDs(
                            config.listenHost,
                            config.listenPort
                        )
                    )
                    dependencies.stderr(message)
                    return 1
                }
                throw error
            }
        } catch let error as ProxyServerCommandError {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch let error as CLIError {
            dependencies.stderr(error.description)
            dependencies.stderr(Self.serverUsage())
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }

    package static func parseOptions(args: [String]) throws -> ProxyServerOptions {
        var forwarded: [String] = []
        var showHelp = false
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
                showHelp = true
                return ProxyServerOptions(
                    forwardedArgs: forwarded,
                    showHelp: showHelp,
                    hasListenFlag: hasListen,
                    hasHostFlag: hasHost,
                    hasPortFlag: hasPort,
                    hasXcodePidFlag: hasXcodePid,
                    hasLazyInitFlag: hasLazyInit,
                    forceRestart: forceRestart,
                    dryRun: dryRun
                )
            case "--dry-run":
                dryRun = true
                index += 1
                continue
            case "--force-restart":
                forceRestart = true
                index += 1
                continue
            case "--stdio":
                throw ProxyServerCommandError.message(
                    "--stdio is not supported in server mode (use xcode-mcp-proxy)"
                )
            case "--url":
                throw ProxyServerCommandError.message(
                    "--url is not supported in server mode (use xcode-mcp-proxy)"
                )
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
                    throw ProxyServerCommandError.message("\(arg) requires a value")
                }
                forwarded.append(args[index + 1])
                index += 2
            } else {
                index += 1
            }
        }

        return ProxyServerOptions(
            forwardedArgs: forwarded,
            showHelp: showHelp,
            hasListenFlag: hasListen,
            hasHostFlag: hasHost,
            hasPortFlag: hasPort,
            hasXcodePidFlag: hasXcodePid,
            hasLazyInitFlag: hasLazyInit,
            forceRestart: forceRestart,
            dryRun: dryRun
        )
    }

    package static func applyDefaults(
        from environment: [String: String],
        to options: inout ProxyServerOptions,
        resolveXcodePid: () -> String?,
        stderr: (String) -> Void
    ) {
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
            options.forwardedArgs += ["--port", "8765"]
        }

        if !options.hasXcodePidFlag {
            if let explicit = nonEmpty(environment["XCODE_PID"]) ?? nonEmpty(environment["MCP_XCODE_PID"]) {
                options.forwardedArgs += ["--xcode-pid", explicit]
            } else if let resolved = resolveXcodePid() {
                options.forwardedArgs += ["--xcode-pid", resolved]
            } else {
                stderr("warning: Xcode PID not found; running without --xcode-pid.")
            }
        }

        if !options.hasLazyInitFlag, isTruthy(environment["LAZY_INIT"]) {
            options.forwardedArgs.append("--lazy-init")
        }
    }

    package static func serverUsage() -> String {
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

    package static func portInUseMessage(host: String, port: Int, pids: [Int]) -> String {
        let displayHost: String = {
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
        lines.append(
            "強制再開始する場合は `--force-restart` を付けて再実行すると、既存の xcode-mcp-proxy-server を終了して起動し直します。"
        )
        lines.append("")
        lines.append("例:")
        lines.append("  pkill -x xcode-mcp-proxy-server")
        lines.append("  xcode-mcp-proxy-server --force-restart")
        return lines.joined(separator: "\n")
    }

    package static func nonEmpty(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    package static func isTruthy(_ value: String?) -> Bool {
        guard let raw = nonEmpty(value) else { return false }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    package static func isAddressAlreadyInUse(_ error: Error) -> Bool {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("Address already in use") {
            return true
        }
        return text.contains("errno: \(EADDRINUSE)")
    }

    package static func hostMatches(requestedHost: String, actualHost: String) -> Bool {
        let requested = normalizeHost(requestedHost)
        let actual = normalizeHost(actualHost)

        if isWildcardHost(requested) { return true }
        if isWildcardHost(actual) { return true }

        if requested == "localhost" {
            return actual == "localhost" || actual == "127.0.0.1" || actual == "::1"
        }
        if actual == "localhost" {
            return requested == "localhost" || requested == "127.0.0.1" || requested == "::1"
        }

        return requested == actual
    }

    private static func resolveXcodePid() -> String? {
        if let pid = firstLine(runCommand("/usr/bin/pgrep", ["-x", "Xcode"])) {
            return pid
        }
        if let pid = firstLine(
            runCommand("/usr/bin/pgrep", ["-f", "/Applications/Xcode.*\\.app/Contents/MacOS/Xcode"])
        ) {
            return pid
        }
        if let pid = firstLine(
            runCommand("/usr/bin/pgrep", ["-f", "Xcode.app/Contents/MacOS/Xcode"])
        ) {
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

    @discardableResult
    private static func terminateExistingProxyServerIfNeeded(host: String, port: Int) -> Bool {
        if let record = Discovery.read(),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host) {
            let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
            if record.pid != currentPID, isProxyServerProcess(pid: record.pid) {
                FileHandle.writeLine(
                    "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(record.pid)); terminating it.",
                    to: .standardError
                )
                if terminate(pid: record.pid) {
                    waitForPortToBeFree(host: host, port: port, timeout: 2.0)
                    return true
                }
            }
        }

        let pids = listeningPIDs(onTCPPort: port, matchingHost: host)
        guard !pids.isEmpty else { return false }

        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        var didTerminate = false
        for pid in pids where pid != currentPID {
            guard isProxyServerProcess(pid: pid) else { continue }
            FileHandle.writeLine(
                "warning: port \(port) is already in use by xcode-mcp-proxy-server (pid: \(pid)); terminating it.",
                to: .standardError
            )
            if terminate(pid: pid) {
                didTerminate = true
            }
        }
        if didTerminate {
            waitForPortToBeFree(host: host, port: port, timeout: 2.0)
        }
        return didTerminate
    }

    private static func detectExistingProxyServerPIDs(host: String, port: Int) -> [Int] {
        var pids: [Int] = []
        pids.reserveCapacity(4)

        if let record = Discovery.read(),
           record.port == port,
           hostMatches(requestedHost: host, actualHost: record.host),
           isProxyServerProcess(pid: record.pid) {
            pids.append(record.pid)
        }

        for pid in listeningPIDs(onTCPPort: port, matchingHost: host) where isProxyServerProcess(pid: pid) {
            pids.append(pid)
        }

        var seen = Set<Int>()
        return pids.filter { seen.insert($0).inserted }
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
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

    private static func firstLine(_ output: String?) -> String? {
        guard let output else { return nil }
        return output.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.lowercased()
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        let value = normalizeHost(host)
        return value.isEmpty || value == "*" || value == "0.0.0.0" || value == "::"
    }

    private static func extractListenerHost(fromLsofName name: String) -> String? {
        guard name.hasPrefix("TCP ") else { return nil }
        let rest = name.dropFirst(4)
        guard let endpoint = rest.split(whereSeparator: \.isWhitespace).first else { return nil }
        let endpointString = String(endpoint)
        if endpointString.hasPrefix("["),
           let close = endpointString.firstIndex(of: "]") {
            let start = endpointString.index(after: endpointString.startIndex)
            return String(endpointString[start..<close])
        }
        guard let colon = endpointString.lastIndex(of: ":") else { return nil }
        return String(endpointString[..<colon])
    }

    private static func listeningPIDs(onTCPPort port: Int, matchingHost host: String) -> [Int] {
        if isWildcardHost(host) {
            return listeningPIDs(onTCPPort: port)
        }

        guard let output = runCommand(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return []
        }

        var pids: [Int] = []
        pids.reserveCapacity(4)

        var currentPID: Int?
        var currentMatched = false

        func flush() {
            if let pid = currentPID, currentMatched {
                pids.append(pid)
            }
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let first = rawLine.first else { continue }
            if first == "p" {
                flush()
                currentPID = Int(rawLine.dropFirst())
                currentMatched = false
                continue
            }
            if first == "n" {
                let name = String(rawLine.dropFirst())
                if let listenerHost = extractListenerHost(fromLsofName: name),
                   hostMatches(requestedHost: host, actualHost: listenerHost) {
                    currentMatched = true
                }
            }
        }
        flush()

        var seen = Set<Int>()
        return pids.filter { seen.insert($0).inserted }
    }

    private static func listeningPIDs(onTCPPort port: Int) -> [Int] {
        guard let output = runCommand(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ) else {
            return []
        }
        let lines = output.split(whereSeparator: \.isNewline)
        return lines.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func isProxyServerProcess(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        guard
            let commandLine = firstLine(
                runCommand("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="])
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !commandLine.isEmpty,
            let executable = commandLine.split(whereSeparator: \.isWhitespace).first.map(String.init),
            !executable.isEmpty
        else {
            return false
        }
        return URL(fileURLWithPath: executable).lastPathComponent == "xcode-mcp-proxy-server"
    }

    private static func terminate(pid: Int) -> Bool {
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

    private static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid_t(pid), 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func waitForProcessExit(pid: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isProcessAlive(pid)
    }

    private static func waitForPortToBeFree(host: String, port: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listeningPIDs(onTCPPort: port, matchingHost: host).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
