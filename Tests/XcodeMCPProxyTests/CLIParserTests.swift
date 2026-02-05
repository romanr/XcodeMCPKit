import Testing
@testable import XcodeMCPProxy

@Test func cliParsesListenAddress() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--listen", "0.0.0.0:9999"],
        environment: [:]
    )
    #expect(config.listenHost == "0.0.0.0")
    #expect(config.listenPort == 9999)
}

@Test func cliParsesHostAndPort() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--host", "localhost", "--port", "8080"],
        environment: [:]
    )
    #expect(config.listenHost == "localhost")
    #expect(config.listenPort == 8080)
}

@Test func cliParsesTimeoutAndLazyInit() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--request-timeout", "12", "--lazy-init"],
        environment: [:]
    )
    #expect(config.requestTimeout == 12)
    #expect(config.eagerInitialize == false)
}

@Test func cliUsesEnvironmentOverrides() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy"],
        environment: [
            "MCP_XCODE_PID": "1234",
            "MCP_XCODE_SESSION_ID": "session-xyz",
        ]
    )
    #expect(config.xcodePID == 1234)
    #expect(config.upstreamSessionID == "session-xyz")
}

@Test func cliParsesStdioUpstream() async throws {
    let config = try CLIParser.parse(
        args: [
            "xcode-mcp-proxy",
            "--stdio",
            "http://localhost:8765/mcp",
        ],
        environment: [:]
    )
    #expect(config.transport == .stdio)
    #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
}

@Test func cliDefaultsStdioUpstream() async throws {
    let config = try CLIParser.parse(
        args: [
            "xcode-mcp-proxy",
            "--stdio",
        ],
        environment: [:]
    )
    #expect(config.transport == .stdio)
    #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
}

@Test func cliDefaultsToHTTP() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy"],
        environment: [:]
    )
    #expect(config.transport == .http)
    #expect(config.stdioUpstreamURL == nil)
}
