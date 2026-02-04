import Foundation
import Logging
import NIO
import NIOHTTP1

public final class ProxyServer {
    private let config: ProxyConfig
    private let group: EventLoopGroup
    private let sessionManager: SessionManager
    private var channel: Channel?
    private let logger: Logger = ProxyLogging.make("server")

    public init(config: ProxyConfig) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.sessionManager = SessionManager(config: config, eventLoop: group.next())
    }

    public func run() throws {
        let channel = try start()
        let (host, port) = resolvedListenAddress(for: channel)
        logger.info("Xcode MCP proxy listening on http://\(host):\(port)")
        try channel.closeFuture.wait()
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

        let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
        self.channel = channel
        return channel
    }

    public func shutdownGracefully() -> EventLoopFuture<Void> {
        let promise = group.next().makePromise(of: Void.self)
        sessionManager.shutdown()
        if let channel {
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
}
