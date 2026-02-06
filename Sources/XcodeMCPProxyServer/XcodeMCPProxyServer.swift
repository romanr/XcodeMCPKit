import Foundation
import XcodeMCPProxy

private struct ServerOptions {
    var forwardedArgs: [String]
    var hasListenFlag: Bool
    var hasHostFlag: Bool
    var hasPortFlag: Bool
    var hasXcodePidFlag: Bool
    var hasLazyInitFlag: Bool
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
                let command = (["xcode-mcp-proxy"] + options.forwardedArgs).joined(separator: " ")
                print(command)
                return
            }

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            let server = ProxyServer(config: config)
            try await server.run()
        } catch let error as ServerError {
            writeError("error: \(error.description)")
            writeError("run with --help for usage")
            exit(1)
        } catch let error as CLIError {
            writeError("\(error.description)")
            if !error.description.contains("Usage:") {
                writeError(CLIParser.usage())
            }
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
        case "--stdio":
            throw ServerError.message("--stdio is not supported in server mode (use xcode-mcp-proxy --stdio)")
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
        dryRun: dryRun
    )
}

private func applyDefaults(from environment: [String: String], to options: inout ServerOptions) {
    if !options.hasListenFlag && !options.hasHostFlag && !options.hasPortFlag {
        if let listen = nonEmpty(environment["LISTEN"]) {
            options.forwardedArgs += ["--listen", listen]
        } else {
            let host = environment["HOST"] ?? "localhost"
            let port = environment["PORT"] ?? "0"
            if nonEmpty(environment["HOST"]) != nil || nonEmpty(environment["PORT"]) != nil {
                options.forwardedArgs += ["--listen", "\(host):\(port)"]
            }
        }
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
    let text = """
    Usage:
      xcode-mcp-proxy-server [options]

    Options:
      --listen host:port
      --host host
      --port port
      --upstream-processes n
      --xcode-pid pid
      --lazy-init
      --dry-run
      -h, --help

    Notes:
      - Uses the same options as xcode-mcp-proxy (except --stdio).
      - Xcode PID is detected automatically when not specified.
    """
    print(text)
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
