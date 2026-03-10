import Testing

@testable import XcodeMCPProxy

@Suite
struct ProcessRunnerTests {
    @Test func processRunnerDrainsLargeStdoutWithoutHanging() async throws {
        let runner = ProcessRunner()
        let output = try await runner.run(
            ProcessRequest(
                label: "large-stdout",
                executablePath: "/bin/sh",
                arguments: ["-c", "yes x | head -c 200000"],
                input: nil
            )
        )

        #expect(output.terminationStatus == 0)
        #expect(output.stdout.utf8.count == 200000)
    }
}
