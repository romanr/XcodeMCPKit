import Foundation

package struct InstallOptions {
    package var prefix: String?
    package var bindir: String?
    package var dryRun: Bool

    package init(prefix: String?, bindir: String?, dryRun: Bool) {
        self.prefix = prefix
        self.bindir = bindir
        self.dryRun = dryRun
    }
}

package enum InstallCommandError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct XcodeMCPProxyInstallCommand {
    package struct Dependencies {
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var executableURL: () -> URL?
        package var buildProducts: ([String], URL) throws -> Void

        package init(
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            executableURL: @escaping () -> URL?,
            buildProducts: @escaping ([String], URL) throws -> Void
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.executableURL = executableURL
            self.buildProducts = buildProducts
        }

        package static var live: Self {
            Self(
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                executableURL: { Bundle.main.executableURL },
                buildProducts: XcodeMCPProxyInstallCommand.buildProducts
            )
        }
    }

    package static let binaryNames = [
        "xcode-mcp-proxy",
        "xcode-mcp-proxy-server",
    ]

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            dependencies.stdout(Self.usage())
            return 0
        }

        do {
            let options = try Self.parseOptions(args, environment: environment)
            guard let executableURL = dependencies.executableURL() else {
                throw InstallCommandError.message("failed to locate installer executable")
            }
            try Self.install(
                options: options,
                executableURL: executableURL,
                buildProducts: dependencies.buildProducts,
                stdout: dependencies.stdout
            )
            return 0
        } catch let error as InstallCommandError {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
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

    package static func install(
        options: InstallOptions,
        executableURL: URL,
        fileManager: FileManager = .default,
        buildProducts: ([String], URL) throws -> Void,
        stdout: (String) -> Void
    ) throws {
        let baseURL = executableURL.deletingLastPathComponent()
        let binDir = resolveBinDir(prefix: options.prefix, bindir: options.bindir)

        if options.dryRun {
            stdout("Would create: \(binDir.path)")
            for name in binaryNames {
                stdout("Would install: \(binDir.appendingPathComponent(name).path)")
            }
            return
        }

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        if let repoRoot = repositoryRoot(from: executableURL),
           fileManager.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
            try buildProducts(binaryNames, repoRoot)
        }

        for name in binaryNames {
            let sourceURL = baseURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw InstallCommandError.message(
                    "\(name) not found next to installer (run with `swift run -c release` from the repo root)"
                )
            }

            let destinationURL = binDir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )
            stdout("Installed \(name) to \(destinationURL.path)")
        }
    }

    package static func repositoryRoot(from executableURL: URL) -> URL? {
        var current = executableURL
        while current.path != "/" {
            if current.lastPathComponent == ".build" {
                return current.deletingLastPathComponent()
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func buildProducts(_ products: [String], in directory: URL) throws {
        for product in products {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "build", "-c", "release", "--product", product]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallCommandError.message(
                    "swift build failed; run from the repo root and try again"
                )
            }
        }
    }
}
