import Foundation
import Testing
@testable import XcodeMCPProxy

private func makeTempDiscoveryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("endpoint.json")
}

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

@Test func cliAllowsListenPortZero() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--listen", "localhost:0"],
        environment: [:]
    )
    #expect(config.listenHost == "localhost")
    #expect(config.listenPort == 0)
}

@Test func cliParsesTimeoutAndLazyInit() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--request-timeout", "12", "--lazy-init"],
        environment: [:]
    )
    #expect(config.requestTimeout == 12)
    #expect(config.eagerInitialize == false)
}

@Test func cliParsesUpstreamProcesses() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy", "--upstream-processes", "10"],
        environment: [:]
    )
    #expect(config.upstreamProcessCount == 10)
}

@Test func cliRejectsInvalidUpstreamProcesses() async throws {
    do {
        _ = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--upstream-processes", "0"],
            environment: [:]
        )
        #expect(Bool(false))
    } catch {}

    do {
        _ = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--upstream-processes", "11"],
            environment: [:]
        )
        #expect(Bool(false))
    } catch {}

    do {
        _ = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--upstream-processes", "abc"],
            environment: [:]
        )
        #expect(Bool(false))
    } catch {}
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
    #expect(config.stdioUpstreamSource == .explicit)
}

@Test func cliDefaultsStdioUpstreamFallback() async throws {
    let tempURL = makeTempDiscoveryURL()
    let config = try CLIParser.parse(
        args: [
            "xcode-mcp-proxy",
            "--stdio",
        ],
        environment: [:],
        discoveryOverrideURL: tempURL
    )
    #expect(config.transport == .stdio)
    #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
    #expect(config.stdioUpstreamSource == .fallback)
}

@Test func cliDefaultsStdioUpstreamFromDiscovery() async throws {
    let tempURL = makeTempDiscoveryURL()
    let record = DiscoveryRecord(
        url: "http://localhost:5555/mcp",
        host: "localhost",
        port: 5555,
        pid: Int(ProcessInfo.processInfo.processIdentifier),
        updatedAt: Date()
    )
    try Discovery.write(record: record, overrideURL: tempURL)
    let config = try CLIParser.parse(
        args: [
            "xcode-mcp-proxy",
            "--stdio",
        ],
        environment: [:],
        discoveryOverrideURL: tempURL
    )
    #expect(config.transport == .stdio)
    #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:5555/mcp")
    #expect(config.stdioUpstreamSource == .discovery)
}

@Test func cliDefaultsStdioUpstreamFromEnvironment() async throws {
    let tempURL = makeTempDiscoveryURL()
    let config = try CLIParser.parse(
        args: [
            "xcode-mcp-proxy",
            "--stdio",
        ],
        environment: [
            "XCODE_MCP_PROXY_ENDPOINT": "http://localhost:9000/mcp",
        ],
        discoveryOverrideURL: tempURL
    )
    #expect(config.transport == .stdio)
    #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:9000/mcp")
    #expect(config.stdioUpstreamSource == .environment)
}

@Test func cliDefaultsToHTTP() async throws {
    let config = try CLIParser.parse(
        args: ["xcode-mcp-proxy"],
        environment: [:]
    )
    #expect(config.transport == .http)
    #expect(config.stdioUpstreamURL == nil)
    #expect(config.listenPort == 0)
}
