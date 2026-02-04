import Foundation
import Testing

@Test func runProxyUsesProvidedPid() async throws {
    let output = try runProxyScriptOutput(environment: [
        "XCODE_PID": "4242",
        "DRY_RUN": "1",
    ])
    #expect(output.contains("--xcode-pid"))
    #expect(output.contains("4242"))
}

@Test func runProxyAutoDetectsPid() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let pgrepURL = tempDir.appendingPathComponent("pgrep")
    let script = "#!/bin/bash\necho 9999\n"
    try script.write(to: pgrepURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepURL.path)

    let output = try runProxyScriptOutput(environment: [
        "PATH": "\(tempDir.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
        "DRY_RUN": "1",
    ])
    #expect(output.contains("--xcode-pid"))
    #expect(output.contains("9999"))
}

private func runProxyScriptOutput(environment overrides: [String: String]) throws -> String {
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
        environment[key] = value
    }
    environment["XCODE_PID"] = overrides["XCODE_PID"]
    environment["MCP_XCODE_PID"] = overrides["MCP_XCODE_PID"]

    let scriptURL = repositoryRoot()
        .appendingPathComponent("scripts")
        .appendingPathComponent("run_proxy.sh")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", scriptURL.path]
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: stdoutData, encoding: .utf8) ?? ""
    let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        throw ScriptError(exitCode: process.terminationStatus, stderr: errorOutput)
    }

    return output
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private struct ScriptError: Error {
    let exitCode: Int32
    let stderr: String
}
