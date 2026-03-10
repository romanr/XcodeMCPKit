import Foundation
import Logging
import NIO
import NIOHTTP1

public final class ProxyServer {
    private let config: ProxyConfig
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private var channels: [Channel] = []
    private let logger: Logger = ProxyLogging.make("server")

    public init(config: ProxyConfig) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        self.sessionManager = SessionManager(config: config, eventLoop: eventLoop)
    }

    public func run() async throws {
        _ = try startAndWriteDiscovery()
        try await wait()
    }

    public func startAndWriteDiscovery() throws -> (host: String, port: Int) {
        let channel = try start()
        let (host, port) = resolvedListenAddress(for: channel)
        let displayHost = config.listenHost == "localhost" ? "localhost" : host
        writeDiscovery(resolvedHost: host, port: port)
        logger.info("Xcode MCP proxy \(Version.current) listening on http://\(displayHost):\(port)")
        return (host, port)
    }

    public func wait() async throws {
        try await waitForHTTP()
    }

    public func start() throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [sessionManager, config] channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let boundChannels = try bindChannels(using: bootstrap)
        self.channels = boundChannels
        guard let first = boundChannels.first else {
            throw ProxyServerError.failedToBind
        }
        return first
    }

    public func shutdownGracefully() -> EventLoopFuture<Void> {
        let promise = group.next().makePromise(of: Void.self)
        sessionManager.shutdown()
        for channel in channels {
            channel.close(promise: nil)
        }
        group.shutdownGracefully { error in
            if let error {
                promise.fail(error)
            } else {
                promise.succeed(())
            }
        }
        return promise.futureResult
    }

    private func resolvedListenAddress(for channel: Channel) -> (String, Int) {
        if let address = channel.localAddress {
            let host = address.ipAddress ?? config.listenHost
            let port = address.port ?? config.listenPort
            return (host, port)
        }
        return (config.listenHost, config.listenPort)
    }

    private func bindChannels(using bootstrap: ServerBootstrap) throws -> [Channel] {
        if config.listenHost != "localhost" {
            let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
            return [channel]
        }

        var bound: [Channel] = []
        do {
            let v4Channel = try bootstrap.bind(host: "127.0.0.1", port: config.listenPort).wait()
            bound.append(v4Channel)
            let v4Port = v4Channel.localAddress?.port ?? config.listenPort
            guard v4Port > 0 else {
                return bound
            }
            do {
                let v6Channel = try bootstrap.bind(host: "::1", port: v4Port).wait()
                bound.append(v6Channel)
            } catch {
                logger.warning("Failed to bind IPv6 loopback; continuing with IPv4 only", metadata: ["error": "\(error)"])
            }
            return bound
        } catch {
            logger.warning("Failed to bind IPv4 loopback; attempting IPv6 only", metadata: ["error": "\(error)"])
            let v6Channel = try bootstrap.bind(host: "::1", port: config.listenPort).wait()
            return [v6Channel]
        }
    }

    private func waitForHTTP() async throws {
        let futures = channels.map { $0.closeFuture }
        if futures.isEmpty {
            return
        }
        try await EventLoopFuture.andAllSucceed(futures, on: group.next()).get()
    }

    private func writeDiscovery(resolvedHost: String, port: Int) {
        guard let record = Discovery.makeRecord(
            host: discoveryHost(resolvedHost),
            port: port,
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        ) else {
            return
        }
        do {
            try Discovery.write(record: record)
        } catch {
            logger.warning(
                "Failed to write discovery file",
                metadata: [
                    "error": "\(error)",
                    "path": "\(Discovery.defaultFileURL.path)",
                ]
            )
        }
    }

    private func discoveryHost(_ resolvedHost: String) -> String {
        switch config.listenHost {
        case "localhost", "0.0.0.0", "::":
            return "localhost"
        default:
            return resolvedHost
        }
    }
}

private enum ProxyServerError: Error {
    case failedToBind
}
