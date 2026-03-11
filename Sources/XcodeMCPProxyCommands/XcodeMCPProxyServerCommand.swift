import Darwin
import Foundation
import XcodeMCPProxy

extension ProxyServer: ProxyServerCommandServer {}

package struct ProxyServerOptions {
    package var forwardedArgs: [String]
    package var showHelp: Bool
    package var hasListenFlag: Bool
    package var hasHostFlag: Bool
    package var hasPortFlag: Bool
    package var hasXcodePidFlag: Bool
    package var hasLazyInitFlag: Bool
    package var forceRestart: Bool
    package var dryRun: Bool

    package init(
        forwardedArgs: [String],
        showHelp: Bool,
        hasListenFlag: Bool,
        hasHostFlag: Bool,
        hasPortFlag: Bool,
        hasXcodePidFlag: Bool,
        hasLazyInitFlag: Bool,
        forceRestart: Bool,
        dryRun: Bool
    ) {
        self.forwardedArgs = forwardedArgs
        self.showHelp = showHelp
        self.hasListenFlag = hasListenFlag
        self.hasHostFlag = hasHostFlag
        self.hasPortFlag = hasPortFlag
        self.hasXcodePidFlag = hasXcodePidFlag
        self.hasLazyInitFlag = hasLazyInitFlag
        self.forceRestart = forceRestart
        self.dryRun = dryRun
    }
}

package enum ProxyServerCommandError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct XcodeMCPProxyServerCommand {
    package struct Dependencies {
        package var bootstrapLogging: ([String: String]) -> Void
        package var stdout: (String) -> Void
        package var stderr: (String) -> Void
        package var resolveXcodePid: () -> String?
        package var terminateExistingServer: (String, Int) -> Bool
        package var makeServer: (ProxyConfig) -> any ProxyServerCommandServer
        package var isAddressAlreadyInUse: (Error) -> Bool
        package var detectExistingProxyServerPIDs: (String, Int) -> [Int]

        package init(
            bootstrapLogging: @escaping ([String: String]) -> Void,
            stdout: @escaping (String) -> Void,
            stderr: @escaping (String) -> Void,
            resolveXcodePid: @escaping () -> String?,
            terminateExistingServer: @escaping (String, Int) -> Bool,
            makeServer: @escaping (ProxyConfig) -> any ProxyServerCommandServer,
            isAddressAlreadyInUse: @escaping (Error) -> Bool,
            detectExistingProxyServerPIDs: @escaping (String, Int) -> [Int]
        ) {
            self.bootstrapLogging = bootstrapLogging
            self.stdout = stdout
            self.stderr = stderr
            self.resolveXcodePid = resolveXcodePid
            self.terminateExistingServer = terminateExistingServer
            self.makeServer = makeServer
            self.isAddressAlreadyInUse = isAddressAlreadyInUse
            self.detectExistingProxyServerPIDs = detectExistingProxyServerPIDs
        }

        package static var live: Self {
            Self(
                bootstrapLogging: ProxyLogging.bootstrap,
                stdout: { print($0) },
                stderr: { FileHandle.writeLine($0, to: .standardError) },
                resolveXcodePid: XcodeMCPProxyServerCommand.resolveXcodePid,
                terminateExistingServer: XcodeMCPProxyServerCommand.terminateExistingProxyServerIfNeeded,
                makeServer: { ProxyServer(config: $0) },
                isAddressAlreadyInUse: XcodeMCPProxyServerCommand.isAddressAlreadyInUse,
                detectExistingProxyServerPIDs: XcodeMCPProxyServerCommand.detectExistingProxyServerPIDs
            )
        }
    }

    private let dependencies: Dependencies

    package init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    package func run(args: [String], environment: [String: String]) async -> Int32 {
        dependencies.bootstrapLogging(environment)

        do {
            var options = try Self.parseOptions(args: args)
            if options.showHelp {
                dependencies.stdout(Self.serverUsage())
                return 0
            }
            Self.applyDefaults(
                from: environment,
                to: &options,
                resolveXcodePid: dependencies.resolveXcodePid,
                stderr: dependencies.stderr
            )

            let isDryRun = options.dryRun || Self.isTruthy(environment["DRY_RUN"])
            if isDryRun {
                let command = (["xcode-mcp-proxy-server"] + options.forwardedArgs)
                    .joined(separator: " ")
                dependencies.stdout(command)
                return 0
            }

            let proxyArgs = ["xcode-mcp-proxy"] + options.forwardedArgs
            let config = try CLIParser.parse(args: proxyArgs, environment: environment)
            if options.forceRestart, config.listenPort > 0 {
                _ = dependencies.terminateExistingServer(config.listenHost, config.listenPort)
            }

            do {
                let server = dependencies.makeServer(config)
                _ = try server.startAndWriteDiscovery()
                try await server.wait()
                return 0
            } catch {
                if config.listenPort > 0, dependencies.isAddressAlreadyInUse(error) {
                    let message = Self.portInUseMessage(
                        host: config.listenHost,
                        port: config.listenPort,
                        pids: dependencies.detectExistingProxyServerPIDs(
                            config.listenHost,
                            config.listenPort
                        )
                    )
                    dependencies.stderr(message)
                    return 1
                }
                throw error
            }
        } catch let error as ProxyServerCommandError {
            dependencies.stderr("error: \(error.description)")
            dependencies.stderr("run with --help for usage")
            return 1
        } catch let error as CLIError {
            dependencies.stderr(error.description)
            dependencies.stderr(Self.serverUsage())
            return 1
        } catch {
            dependencies.stderr("error: \(error)")
            return 1
        }
    }
}
