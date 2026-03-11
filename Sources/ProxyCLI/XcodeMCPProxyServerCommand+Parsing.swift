import Foundation
import XcodeMCPProxy

extension XcodeMCPProxyServerCommand {
    package static func parseOptions(args: [String]) throws -> ProxyServerOptions {
        let scan = try ProxyCLIInvocationScanner.scanServer(args)
        return ProxyServerOptions(
            forwardedArgs: scan.forwardedArgs,
            showHelp: scan.showHelp,
            hasListenFlag: scan.hasListenFlag,
            hasHostFlag: scan.hasHostFlag,
            hasPortFlag: scan.hasPortFlag,
            hasXcodePidFlag: scan.hasXcodePidFlag,
            hasLazyInitFlag: scan.hasLazyInitFlag,
            forceRestart: scan.forceRestart,
            dryRun: scan.dryRun
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
}
