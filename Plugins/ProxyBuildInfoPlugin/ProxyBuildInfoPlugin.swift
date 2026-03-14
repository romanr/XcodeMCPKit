import Foundation
import PackagePlugin

@main
struct ProxyBuildInfoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target is SourceModuleTarget else {
            return []
        }

        let outputFile = context.pluginWorkDirectoryURL.appending(path: "BuildInfo.generated.swift")
        let tool = try context.tool(named: "ProxyBuildInfoTool")
        let version = resolveBuildVersion(
            environment: ProcessInfo.processInfo.environment,
            packageDirectory: context.package.directoryURL
        )

        return [
            .buildCommand(
                displayName: "Generate build info for \(target.name)",
                executable: tool.url,
                arguments: [
                    "--output", outputFile.path,
                    "--version", version,
                ],
                outputFiles: [outputFile]
            )
        ]
    }

    private func resolveBuildVersion(
        environment: [String: String],
        packageDirectory: URL
    ) -> String {
        if let version = normalized(environment["XCODE_MCP_BUILD_VERSION"]) {
            return version
        }

        if let version = try? gitDescribe(in: packageDirectory),
           let normalizedVersion = normalized(version)
        {
            return normalizedVersion
        }

        return "dev"
    }

    private func normalized(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func gitDescribe(in packageDirectory: URL) throws -> String? {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", packageDirectory.path,
            "describe",
            "--tags",
            "--always",
            "--dirty",
        ]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
