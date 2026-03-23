import Testing

@testable import XcodeMCPProxy

struct ProxyServerTests {
    @Test func firstXcrunToolSelectionTreatsLogAsFlagWithoutValue() {
        let selection = ProxyServer.firstXcrunToolSelection(
            from: ["--sdk", "macosx", "--log", "mcpbridge", "--some-flag"]
        )

        #expect(selection?.toolName == "mcpbridge")
        #expect(selection?.preToolArguments == ["--sdk", "macosx", "--log"])
    }
}
