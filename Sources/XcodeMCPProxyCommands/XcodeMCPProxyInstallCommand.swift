import Foundation

package struct InstallOptions {
    package var prefix: String?
    package var bindir: String?
    package var dryRun: Bool
    package var showHelp: Bool

    package init(prefix: String?, bindir: String?, dryRun: Bool, showHelp: Bool = false) {
        self.prefix = prefix
        self.bindir = bindir
        self.dryRun = dryRun
        self.showHelp = showHelp
    }
}

package struct InstallCommandInvocation {
    package var showHelp = false
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
        let invocation = Self.scanInvocation(args)
        if invocation.showHelp {
            dependencies.stdout(Self.usage())
            return 0
        }

        do {
            let options = try Self.parseOptions(args, environment: environment)
            if options.showHelp {
                dependencies.stdout(Self.usage())
                return 0
            }
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
