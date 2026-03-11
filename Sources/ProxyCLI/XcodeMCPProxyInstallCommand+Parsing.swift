import Foundation

extension XcodeMCPProxyInstallCommand {
    package static func scanInvocation(_ args: [String]) -> InstallCommandInvocation {
        var invocation = InstallCommandInvocation()
        var index = 1

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                invocation.showHelp = true
                index += 1
            case "--prefix", "--bindir":
                index += min(2, args.count - index)
            case "--dry-run":
                index += 1
            default:
                index += 1
            }
        }

        return invocation
    }

    package static func usage() -> String {
        """
        Usage:
          xcode-mcp-proxy-install [--bindir path] [--prefix path] [--dry-run]

        Options:
          --bindir path   Install to this directory (overrides --prefix)
          --prefix path   Install to <prefix>/bin (default: ~/.local)
          --dry-run       Print actions without copying files
          -h, --help      Show this help

        Examples:
          swift run -c release xcode-mcp-proxy-install
          swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
        """
    }

    package static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    package static func parseOptions(
        _ args: [String],
        environment: [String: String]
    ) throws -> InstallOptions {
        var options = InstallOptions(
            prefix: environment["PREFIX"],
            bindir: environment["BINDIR"],
            dryRun: false
        )

        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                options.showHelp = true
                index += 1
            case "--prefix":
                guard index + 1 < args.count else {
                    throw InstallCommandError.message("--prefix requires a value")
                }
                options.prefix = args[index + 1]
                index += 2
            case "--bindir":
                guard index + 1 < args.count else {
                    throw InstallCommandError.message("--bindir requires a value")
                }
                options.bindir = args[index + 1]
                index += 2
            case "--dry-run":
                options.dryRun = true
                index += 1
            default:
                throw InstallCommandError.message("unknown option: \(arg)")
            }
        }

        return options
    }

    package static func resolveBinDir(prefix: String?, bindir: String?) -> URL {
        if let bindir {
            return URL(fileURLWithPath: expandPath(bindir), isDirectory: true)
        }

        let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
        let expandedPrefix = expandPath(defaultPrefix)
        return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}
