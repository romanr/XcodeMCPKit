import Foundation
import Testing
import XcodeMCPProxyCommands

@Suite
struct InstallCommandTests {
    @Test func installCommandParsesOptionsAndPrefersBindir() throws {
        let options = try XcodeMCPProxyInstallCommand.parseOptions(
            [
                "xcode-mcp-proxy-install",
                "--prefix", "/tmp/prefix",
                "--bindir", "/tmp/bin",
                "--dry-run",
            ],
            environment: [:]
        )

        #expect(options.prefix == "/tmp/prefix")
        #expect(options.bindir == "/tmp/bin")
        #expect(options.dryRun == true)
        #expect(
            XcodeMCPProxyInstallCommand.resolveBinDir(
                prefix: options.prefix,
                bindir: options.bindir
            ).path == "/tmp/bin"
        )
    }

    @Test func installCommandExpandsHomeRelativePaths() throws {
        let home = NSHomeDirectory()
        let resolved = XcodeMCPProxyInstallCommand.resolveBinDir(
            prefix: "~/custom",
            bindir: nil
        )

        #expect(resolved.path == "\(home)/custom/bin")
    }

    @Test func installCommandFindsRepositoryRootFromBuildProducts() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/repo/.build/debug/xcode-mcp-proxy-install")
        let root = XcodeMCPProxyInstallCommand.repositoryRoot(from: executableURL)

        #expect(root?.path == "/tmp/repo")
    }

    @Test func installCommandReportsMissingBinary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let executableURL = tempDir.appendingPathComponent("xcode-mcp-proxy-install")

        #expect(throws: InstallCommandError.self) {
            try XcodeMCPProxyInstallCommand.install(
                options: InstallOptions(prefix: nil, bindir: tempDir.path, dryRun: false),
                executableURL: executableURL,
                buildProducts: { _, _ in },
                stdout: { _ in }
            )
        }
    }

    @Test func installCommandPrintsUsageForHelp() throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { _ in },
                executableURL: { nil },
                buildProducts: { _, _ in }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--help"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }

    @Test func installCommandTreatsHelpOnlyAsTopLevelFlag() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                executableURL: { URL(fileURLWithPath: "/tmp/xcode-mcp-proxy-install") },
                buildProducts: { _, _ in }
            )
        )

        let exitCode = command.run(
            args: [
                "xcode-mcp-proxy-install",
                "--bindir", "--help",
                "--dry-run",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        #expect(output.snapshot().isEmpty == false)
        #expect(output.snapshot().first?.contains("Usage:") == false)
    }

    @Test func installCommandPreservesExplicitHelpBeforeParseErrors() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                executableURL: { nil },
                buildProducts: { _, _ in }
            )
        )

        let exitCode = command.run(
            args: [
                "xcode-mcp-proxy-install",
                "--help",
                "--unknown",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }
}
