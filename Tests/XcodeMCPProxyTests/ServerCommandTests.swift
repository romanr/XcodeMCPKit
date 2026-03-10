import Foundation
import Testing
import XcodeMCPProxy
import XcodeMCPProxyCommands

@Suite
struct ServerCommandTests {
    @Test func serverCommandParsesForceRestartAndDryRun() throws {
        let options = try XcodeMCPProxyServerCommand.parseOptions(args: [
            "xcode-mcp-proxy-server",
            "--listen",
            "127.0.0.1:9000",
            "--force-restart",
            "--dry-run",
        ])

        #expect(options.forwardedArgs == ["--listen", "127.0.0.1:9000"])
        #expect(options.showHelp == false)
        #expect(options.hasListenFlag == true)
        #expect(options.forceRestart == true)
        #expect(options.dryRun == true)
    }

    @Test func serverCommandAppliesEnvironmentDefaultsAndResolvedXcodePID() throws {
        var options = ProxyServerOptions(
            forwardedArgs: [],
            showHelp: false,
            hasListenFlag: false,
            hasHostFlag: false,
            hasPortFlag: false,
            hasXcodePidFlag: false,
            hasLazyInitFlag: false,
            forceRestart: false,
            dryRun: false
        )

        XcodeMCPProxyServerCommand.applyDefaults(
            from: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "LAZY_INIT": "1",
            ],
            to: &options,
            resolveXcodePid: { "4242" },
            stderr: { _ in }
        )

        #expect(options.forwardedArgs == [
            "--listen", "127.0.0.1:9999",
            "--xcode-pid", "4242",
            "--lazy-init",
        ])
    }

    @Test func serverCommandFormatsPortInUseMessage() throws {
        let message = XcodeMCPProxyServerCommand.portInUseMessage(
            host: "::1",
            port: 8765,
            pids: [111, 222]
        )

        #expect(message.contains("listen [::1]:8765"))
        #expect(message.contains("pids: 111, 222"))
        #expect(message.contains("--force-restart"))
    }

    @Test func serverCommandHostMatchingHandlesLoopbackAndWildcard() throws {
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "localhost",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "::",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "127.0.0.1",
                actualHost: "::1"
            ) == false
        )
    }

    @Test func serverCommandInvokesForceRestartBeforeStartingInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                stderr: { _ in },
                resolveXcodePid: { "1234" },
                terminateExistingServer: { host, port in
                    restarted.append("\(host):\(port)")
                    return true
                },
                makeServer: { config in
                    fakeServer.record(config: config)
                    return fakeServer
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9000",
                "--force-restart",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:9000"])
        let config = try #require(fakeServer.recordedConfig())
        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9000)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }

    @Test func serverCommandDryRunPrintsResolvedCommand() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                resolveXcodePid: { "5678" },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "LAZY_INIT": "true",
            ]
        )

        #expect(exitCode == 0)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("--listen 127.0.0.1:9999"))
        #expect(line.contains("--xcode-pid 5678"))
        #expect(line.contains("--lazy-init"))
    }

    @Test func serverCommandTreatsHelpOnlyAsTopLevelFlag() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                resolveXcodePid: { "7777" },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--upstream-arg", "--help",
                "--dry-run",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("--upstream-arg --help"))
        #expect(line.contains("--xcode-pid 7777"))
        #expect(line.contains("Usage:") == false)
    }
}

private final class RecordingProxyServer: ProxyServerCommandServer {
    private let state = LockedBox(
        (config: Optional<ProxyConfig>.none, startCount: 0, waitCount: 0)
    )

    func record(config: ProxyConfig) {
        state.withValue { value in
            value.config = config
        }
    }

    func startAndWriteDiscovery() throws -> (host: String, port: Int) {
        state.withValue { value in
            value.startCount += 1
        }
        return ("127.0.0.1", 8765)
    }

    func wait() async throws {
        state.withValue { value in
            value.waitCount += 1
        }
    }

    func recordedConfig() -> ProxyConfig? {
        state.snapshot().config
    }

    func startCount() -> Int {
        state.snapshot().startCount
    }

    func waitCount() -> Int {
        state.snapshot().waitCount
    }
}
