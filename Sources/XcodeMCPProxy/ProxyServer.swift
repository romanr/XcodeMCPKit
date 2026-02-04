import Foundation
import NIO
import NIOHTTP1

final class ProxyServer {
    private let config: ProxyConfig
    private let group: EventLoopGroup
    private let sessionManager: SessionManager

    init(config: ProxyConfig) {
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.sessionManager = SessionManager(config: config)
    }

    func run() throws {
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
        print("Xcode MCP proxy listening on http://\(config.listenHost):\(config.listenPort)")
        try channel.closeFuture.wait()
    }
}
