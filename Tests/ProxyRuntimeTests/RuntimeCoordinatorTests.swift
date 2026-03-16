import Foundation
import NIO
import Testing
import ProxyCore
import XcodeMCPTestSupport
@testable import ProxyRuntime

@Suite(.serialized)
struct RuntimeCoordinatorTests {
    @Test func defaultUpstreamsDoNotInjectXcodePIDEnvironment() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_PID"] == nil)
    }

    @Test func defaultUpstreamsPassThroughInheritedMCPXcodePIDEnvironment() async throws {
        let environment = try withEnvironmentVariables(
            [
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ]
        ) {
            try defaultUpstreamEnvironment(sharedSessionID: nil)
        }

        #expect(environment["XCODE_PID"] == nil)
        #expect(environment["MCP_XCODE_PID"] == "5678")
    }

    @Test func defaultUpstreamsDoNotInjectSessionIDWhenConfigDoesNotSpecifyOne() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_SESSION_ID"] == nil)
    }

    @Test func defaultUpstreamsInjectExplicitSessionIDWhenConfigured() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: "session-explicit")

        #expect(environment["MCP_XCODE_SESSION_ID"] == "session-explicit")
    }

    @Test func sessionManagerQueuesInitializeRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let request1 = makeInitializeRequest(id: 1)
        let request2 = makeInitializeRequest(id: 2)
        let future1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: request1,
            on: eventLoop
        )
        let future2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: request2,
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }

        let upstreamID = try extractUpstreamID(from: sent[0])
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        let response1 = try decodeJSON(from: try await future1.get())
        let response2 = try decodeJSON(from: try await future2.get())
        let id1 = (response1["id"] as? NSNumber)?.intValue
        let id2 = (response2["id"] as? NSNumber)?.intValue
        #expect(id1 == 1)
        #expect(id2 == 2)
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        await upstream.yield(.message(notification))

        _ = try await future.get()
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerRoutesUnmappedNotificationsDuringInitializeHandshake() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 99],
            ],
            options: []
        )
        await upstream.yield(.message(notification))

        let received = try await nextBufferedNotifications(from: session.router)
        #expect(received.count == 1)
        #expect(received.first == notification)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await future.get()
    }

    @Test func sessionManagerDropsUnmappedNotificationsForCachedInitializeSessions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let firstFuture = manager.registerInitialize(
            sessionID: "session-A",
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let firstSent = await upstream.sent()
        let firstInitID = try extractUpstreamID(from: firstSent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: firstInitID)))
        _ = try await firstFuture.get()

        let sessionID = "session-B"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()
        let cachedFuture = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 2],
            ],
            options: []
        )
        await upstream.yield(.message(notification))

        _ = try await cachedFuture.get()
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDoesNotRecreateRemovedSessionWhenInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-removed"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        _ = try await future.get()
        #expect(manager.hasSession(id: sessionID) == false)
    }

    @Test func sessionManagerDoesNotApplyRemovedInitializeStateToRecreatedSession() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)
        let replacement = manager.session(id: sessionID)
        _ = replacement.router.drainBufferedNotifications()

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 7],
            ],
            options: []
        )
        await upstream.yield(.message(notification))

        _ = try await future.get()
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                replacement.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDoesNotRouteUnmappedNotificationsToCachedInitializeSessions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-hinted-pin"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await future.get()

        let notification0 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 0],
            ],
            options: []
        )
        let notification1 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        await upstream0.yield(.message(notification0))
        await upstream1.yield(.message(notification1))

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerTimeoutResetsInitState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 1)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect((await upstream.sent()).count == 1)

        do {
            _ = try await waitWithTimeout(
                "initialize request should fail with TimeoutError",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
            #expect(Bool(false))
        } catch {
            #expect(error is TimeoutError)
        }

        _ = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerShutdownFailsPendingInitializeRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.shutdown()

        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func sessionManagerTimeoutDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.1)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-timeout-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        manager.testSetInitializeRoutingState(
            sessionID: sessionID,
            upstreamIndex: 0,
            preferOnNextPin: true,
            didReceiveInitializeUpstreamMessage: true
        )
        let replacementSnapshotBeforeTimeout = try #require(manager.testSessionSnapshot(id: sessionID))

        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }

        let replacementSnapshotAfterTimeout = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterTimeout.generation == replacementSnapshotBeforeTimeout.generation)
    }

    @Test func sessionManagerInitializeErrorDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-error-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        manager.testSetInitializeRoutingState(
            sessionID: sessionID,
            upstreamIndex: 0,
            preferOnNextPin: true,
            didReceiveInitializeUpstreamMessage: true
        )
        let replacementSnapshotBeforeError = try #require(manager.testSessionSnapshot(id: sessionID))

        await upstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": initID,
                        "error": [
                            "code": -32000,
                            "message": "boom",
                        ],
                    ],
                    options: []
                )
            )
        )

        let response = try decodeJSON(from: try await future.get())
        let errorObject = try #require(response["error"] as? [String: Any])
        #expect(errorObject["message"] as? String == "boom")

        let replacementSnapshotAfterError = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterError.generation == replacementSnapshotBeforeError.generation)
    }

    @Test func sessionManagerEagerInitializeRestartsAfterExit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }
        #expect(manager.isInitialized() == false)

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))

        await upstream.yield(.exit(1))
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        _ = manager
    }

    @Test func initializeTimeoutRemainsBoundedWhenRequestTimeoutIsDisabled() throws {
        let timeout = MCPMethodDispatcher.timeoutForInitialize(defaultSeconds: 0)
        #expect(timeout?.nanoseconds == TimeAmount.seconds(60).nanoseconds)
    }

    @Test func sessionManagerStillAutoInitializesWhenRequestTimeoutIsDisabled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
    }

    @Test func sessionManagerUsesInitializeParamsOverrideFromConfigFile() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "custom-proxy"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
        #expect(capabilities["roots"] as? Bool == true)
    }

    @Test func sessionManagerAutoResolvesInitializeVersionFromConfiguredClientName() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "Claude"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == manager.defaultClientVersion(for: "Claude"))
    }

    @Test func xcodeChatClientVersionFallsBackToCodeAliasWhenExactStemMissing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let version = manager.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "9.9.9")
    }

    @Test func xcodeChatClientVersionPrefersExactStemMatchOverGenericCodeAlias() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let version = manager.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeVersion": #"{"version":"1.2.3"}"#,
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "1.2.3")
    }

    @Test func sessionManagerFallsBackToDefaultInitializeParamsWhenConfigFileIsInvalid()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake
            protocolVersion = "broken"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == manager.defaultProxyClientName())
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
    }

    @Test func sessionManagerUsesConfiguredInitializeParamsAfterEagerInitTimesOut()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "configured-proxy"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 0.1)
        config.configPath = configPath
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.testStateSnapshot()
                return snapshot.initInFlight == false && snapshot.hasInitResult == false
            }
        )

        _ = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2099-01-01",
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": "downstream-client",
                        "version": "9.9",
                    ],
                ],
            ],
            on: eventLoop
        )

        let resent = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: resent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
    }

    @Test func sessionManagerSendsInitializedOnce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        _ = try await future.get()
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

        let cached = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        let cachedResponse = try decodeJSON(from: try await cached.get())
        let cachedID = (cachedResponse["id"] as? NSNumber)?.intValue
        #expect(cachedID == 2)
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerPrimaryExitClearsCachedInitializeResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        // First init establishes the cached init result.
        let init1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID1 = try extractUpstreamID(from: firstInit)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID1)))
        _ = try await init1.get()

        // Wait for notifications/initialized.
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        // Simulate primary upstream dying after init succeeded.
        await upstream.yield(.exit(1))
        try await waitForCondition(timeoutSeconds: 2) {
            manager.testStateSnapshot().hasInitResult == false
        }

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream.sent())[2])
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerSecondaryExitClearsCachedInitializeResultWhenPrimaryAlreadyDown()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // First init establishes the cached init result (primary only).
        let init1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let upstreamID0 = try extractUpstreamID(from: firstInit)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID0)))
        _ = try await init1.get()

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1Messages = await upstream1.sent()
        let upstreamID1 = try extractUpstreamID(from: init1Messages[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: upstreamID1)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[0].isInitialized == false
            }
        )

        // Now simulate the last initialized upstream dying too.
        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // Ensure the cached init result is cleared before asserting that a new downstream initialize
        // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
        // been processed yet on the event loop.
        try await waitForCondition(timeoutSeconds: 2) {
            manager.testStateSnapshot().hasInitResult == false
        }

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream0.sent())[2])
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerEagerInitializeRerunsPrimaryInitWhenLastInitializedUpstreamExits()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))

        // Primary warm init should be attempted, but we simulate it failing.
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[0].initInFlight == false
            }
        )

        // Now simulate the last initialized upstream dying too. Eager init should kick the global init path again.
        await upstream1.yield(.exit(1))
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test
    func
        sessionManagerRetriesEagerInitializeAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        // Primary exit triggers warm init on primary.
        await upstream0.yield(.exit(1))
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)

        // While primary warm init is in flight, last initialized upstream exits.
        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // Warm init fails with JSON-RPC error.
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))

        // Proxy should restart eager/global init automatically.
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Eager init -> upstream0
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        let originalA = RPCID(any: NSNumber(value: 100))!
        let originalB = RPCID(any: NSNumber(value: 101))!

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDB, shouldPin: true))
        #expect(upstreamIndexA != upstreamIndexB)

        let futureA = sessionA.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionIDA,
            originalID: originalA,
            upstreamIndex: upstreamIndexA
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDA), upstreamIndex: upstreamIndexA)

        let futureB = sessionB.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionIDB,
            originalID: originalB,
            upstreamIndex: upstreamIndexB
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)

        await yieldMessage(
            try makeToolListResponse(id: upstreamIDA),
            to: upstreamIndexA == 0 ? upstream0 : upstream1
        )
        await yieldMessage(
            try makeToolListResponse(id: upstreamIDB),
            to: upstreamIndexB == 0 ? upstream0 : upstream1
        )

        _ = try await futureA.get()
        _ = try await futureB.get()

        let methods0 = await upstream0.sent().compactMap(methodName(from:))
        let methods1 = await upstream1.sent().compactMap(methodName(from:))
        #expect(methods0.filter { $0 == "tools/list" }.count == 1)
        #expect(methods1.filter { $0 == "tools/list" }.count == 1)
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeRoutingEnds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        // Ensure we're starting from a clean buffer state.
        _ = sessionA.router.drainBufferedNotifications()
        _ = sessionB.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        await yieldMessage(notification, to: upstream0)
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                sessionA.router.drainBufferedNotifications().isEmpty
                    && sessionB.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDropsUnmappedNotificationsWhenNoPinnedTargetsExist()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Create a session, but do not pin it yet.
        let sessionID = "session-A"
        let session = manager.session(id: sessionID)

        // Ensure we're starting from a clean buffer state.
        _ = session.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        await yieldMessage(notification, to: upstream0)

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true)

        _ = session.router.drainBufferedNotifications()

        // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
        await yieldMessage(try makeToolListResponse(id: 9_999_999), to: upstream)

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDebugSnapshotCapturesTrafficAndStderr() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initMessages = await upstream.sent()
        let initID = try extractUpstreamID(from: initMessages[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-debug"
        let session = manager.session(id: sessionID)
        let upstreamIndex = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        let original = RPCID(any: NSNumber(value: 301))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(1))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: original,
            upstreamIndex: upstreamIndex
        )
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: upstreamIndex)
        await upstream.yield(.message(try makeToolListResponse(id: upstreamID)))
        _ = try await future.get()

        await upstream.yield(.message(try makeToolListResponse(id: 9_999_999)))
        await upstream.yield(
            .stderr("Could not decode agent message: Error Domain=mcpbridge.DecodeError Code=1"))
        await upstream.yield(
            .stderr(
                "callTool request for 'DocumentationSearch' failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
            ))
        await upstream.yield(
            .stdoutProtocolViolation(
                StdioFramerProtocolViolation(
                    reason: .invalidJSON,
                    bufferedByteCount: 1024,
                    preview: "...broken"
                )
            )
        )
        await upstream.yield(.stdoutBufferSize(2048))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.debugSnapshot()
                return snapshot.upstreams[0].bufferedStdoutBytes == 2048
                    && snapshot.upstreams[0].protocolViolationCount == 1
                    && snapshot.upstreams[0].recentStderr.count == 2
            }
        )

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].lastDecodeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].lastBridgeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].protocolViolationCount == 1)
        #expect(snapshot.upstreams[0].lastProtocolViolationReason == "invalidJSON")
        #expect(snapshot.upstreams[0].lastProtocolViolationBufferedBytes == 1024)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(snapshot.upstreams[0].bufferedStdoutBytes == 2048)
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" && $0.bytes > 0 })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound" && $0.preview == "<redacted>"
            })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound_unmapped" && $0.preview == "<redacted>"
            })
        #expect(snapshot.upstreams[0].recentStderr.allSatisfy { $0.message == "<redacted>" })

        await upstream.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.debugSnapshot()
                return snapshot.upstreams[0].recentStderr.isEmpty
                    && snapshot.upstreams[0].lastDecodeError == nil
                    && snapshot.upstreams[0].lastBridgeError == nil
                    && snapshot.upstreams[0].protocolViolationCount == 0
                    && snapshot.upstreams[0].lastProtocolViolationPreview == nil
                    && snapshot.upstreams[0].lastProtocolViolationPreviewHex == nil
                    && snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil
                    && snapshot.upstreams[0].bufferedStdoutBytes == 0
            }
        )

        let clearedSnapshot = manager.debugSnapshot()
        #expect(clearedSnapshot.upstreams[0].recentStderr.isEmpty)
        #expect(clearedSnapshot.upstreams[0].lastDecodeError == nil)
        #expect(clearedSnapshot.upstreams[0].lastBridgeError == nil)
        #expect(clearedSnapshot.upstreams[0].protocolViolationCount == 0)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreview == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreviewHex == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(clearedSnapshot.upstreams[0].bufferedStdoutBytes == 0)
    }

    @Test func sessionManagerReturnsNilWhenAllUpstreamsAreQuarantined() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 2)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize primary upstream0.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1.
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Fail tools/list warmup on upstream0 to mark it unhealthy.
        manager.refreshToolsListIfNeeded()
        let warmup0 = try await sentMessage(
            from: upstream0,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup0ID = try extractUpstreamID(from: warmup0)
        let warmup0Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup0ID,
            "result": [:],  // invalid (no `tools` array) -> marks upstream unhealthy
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup0Response, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                switch manager.testStateSnapshot().upstreams[0].healthState {
                case .healthy:
                    return false
                case .degraded, .quarantined:
                    return true
                }
            }
        )

        // Trigger another warmup; it should prefer upstream1 and fail there too so no healthy upstream exists.
        manager.refreshToolsListIfNeeded()
        let warmup1 = try await sentMessage(
            from: upstream1,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup1ID = try extractUpstreamID(from: warmup1)
        let warmup1Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup1ID,
            "result": [:],
        ]
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup1Response, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.chooseUpstreamIndex(sessionID: "session-A", shouldPin: true) == nil
            }
        )

        let chosen = manager.chooseUpstreamIndex(sessionID: "session-A", shouldPin: true)
        #expect(chosen == nil)
    }

    @Test func sessionManagerRepinsAfterUpstreamExit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Pin two sessions to different upstreams.
        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        _ = manager.session(id: sessionIDA)
        _ = manager.session(id: sessionIDB)

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDB, shouldPin: true))
        #expect(upstreamIndexA != upstreamIndexB)

        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        let repinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
        #expect(repinned == 0)
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamIsQuarantinedByTimeouts() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-timeout-repin"
        _ = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))

        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-1", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-2", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-3", upstreamIndex: pinned)

        let repinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(repinned != pinned)
    }

    @Test func sessionManagerExitClearsMappingsAndKeepsServingOnOtherUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0[0]))))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1[0]))))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-1"
        let session = manager.session(id: sessionID)

        // Send a request to upstream1, then kill upstream1 before it can respond.
        let originalA = RPCID(any: NSNumber(value: 200))!
        let futureA = session.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalA, upstreamIndex: 1)
        manager.sendUpstream(try makeToolListRequest(id: upstreamIDA), upstreamIndex: 1)

        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // The proxy should continue serving on upstream0.
        let originalB = RPCID(any: NSNumber(value: 201))!
        let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(upstreamIndexB == 0)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalB, upstreamIndex: upstreamIndexB)
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)
        await upstream0.yield(.message(try makeToolListResponse(id: upstreamIDB)))
        _ = try await futureB.get()

        // A should time out (mapping is cleared on exit, and no response arrives).
        do {
            _ = try await waitWithTimeout(
                "request routed to exited upstream should fail with TimeoutError",
                timeout: .seconds(2)
            ) {
                try await futureA.get()
            }
            #expect(Bool(false))
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test func sessionManagerReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let sessionID = "session-overloaded"
        let session = manager.session(id: sessionID)
        let original = RPCID(any: NSNumber(value: 910))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: 0)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: 0)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().recentTraffic.contains { $0.direction == "outbound" }
                    == false
            }
        )
        let snapshot = manager.debugSnapshot()
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" } == false)
    }

    @Test func sessionManagerInitializeReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdown() }

        let original = RPCID(any: NSNumber(value: 1001))!
        let future = manager.registerInitialize(
            originalID: original,
            requestObject: makeInitializeRequest(id: 1001),
            on: eventLoop
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "initialize should surface overloaded upstream error",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamBecomesOverloaded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdown() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionID = "session-overload-repin"
        let session = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(pinned == 0)

        await upstream0.setOverloaded(true)

        let original = RPCID(any: NSNumber(value: 920))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: pinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: pinned)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded pinned upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        let repinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(repinned == 1)

        let original2 = RPCID(any: NSNumber(value: 921))!
        let future2 = session.router.registerRequest(
            idKey: original2.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID2 = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original2, upstreamIndex: repinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID2), upstreamIndex: repinned)
        await upstream1.yield(.message(try makeToolListResponse(id: upstreamID2)))
        _ = try await waitWithTimeout(
            "repinned upstream should return response",
            timeout: .seconds(2)
        ) {
            try await future2.get()
        }
    }
}

private func makeConfig(requestTimeout: TimeInterval) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: 1024,
        requestTimeout: requestTimeout,
        prewarmToolsList: false
    )
}

private func defaultUpstreamEnvironment(sharedSessionID: String?) throws -> [String: String] {
    var config = makeConfig(requestTimeout: 5)
    config.upstreamSessionID = sharedSessionID
    let upstreams = RuntimeCoordinator.makeDefaultUpstreams(
        config: config,
        sharedSessionID: sharedSessionID,
        count: 1
    )
    let upstream = try #require(upstreams.first)
    return try upstreamEnvironment(from: upstream)
}

private func upstreamEnvironment(from upstream: UpstreamProcess) throws -> [String: String] {
    let mirror = Mirror(reflecting: upstream)
    let config = try #require(
        mirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess should expose a stored config for tests"
    )
    let configMirror = Mirror(reflecting: config)
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

private func withEnvironmentVariables<T>(
    _ values: [String: String],
    body: () throws -> T
) throws -> T {
    let originalValues = values.keys.reduce(into: [String: String?]()) { result, key in
        result[key] = ProcessInfo.processInfo.environment[key]
    }

    for (key, value) in values {
        _ = unsafe setenv(key, value, 1)
    }

    defer {
        for (key, value) in originalValues {
            if let value {
                _ = unsafe setenv(key, value, 1)
            } else {
                _ = unsafe unsetenv(key)
            }
        }
    }

    return try body()
}

private actor AlwaysOverloadedUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private let sentMessages = RecordedValues<Data>()

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        await sentMessages.append(data)
        return .overloaded
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }
}

private actor ToggleableOverloadUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private var overloaded = false

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func setOverloaded(_ value: Bool) {
        overloaded = value
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        await sentMessages.append(data)
        return overloaded ? .overloaded : .accepted
    }

    func yield(_ event: UpstreamEvent) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }
}

private func makeInitializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "session-manager-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func makeTempProxyConfigFile(_ contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("proxy-config.toml")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
}

private func makeInitializeResponse(id: Int64) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "capabilities": [String: Any]()
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func extractUpstreamID(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
}

private func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    var buffer = buffer
    guard let data = buffer.readData(length: buffer.readableBytes) else {
        return [:]
    }
    return (try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
}

private func waitForSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

private func waitForSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

private enum WaitForSentCountError: Error {
    case timeout(expected: Int, actual: Int)
}

private func waitForCondition(
    timeoutSeconds: UInt64,
    pollNanoseconds: UInt64 = 50_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    _ = pollNanoseconds
    let reached = await waitUntil(timeout: .seconds(Int64(timeoutSeconds))) {
        condition()
    }
    if !reached {
        throw WaitForConditionError.timeout
    }
}

private enum WaitForConditionError: Error {
    case timeout
}

private func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return object["method"] as? String
}

private func makeToolListRequest(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ],
        options: []
    )
}

private func makeToolListResponse(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ],
        options: []
    )
}

private func yieldMessage(_ data: Data, to upstream: TestUpstreamClient) async {
    await upstream.yield(.message(data))
}

private func sentValue(
    from upstream: TestUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

private func sentValue(
    from upstream: ToggleableOverloadUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

private func sentMessage(
    from upstream: TestUpstreamClient,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for matching sent message",
        timeout: timeout
    ) {
        try Task.checkCancellation()
        let sent = await upstream.sent()
        return sent.first(where: predicate)
    }
}

private func nextBufferedNotifications(
    from router: ProxyRouter,
    timeout: Duration = .seconds(5)
) async throws -> [Data] {
    try await waitWithTimeout(
        "waiting for buffered notifications",
        timeout: timeout
    ) {
        while true {
            try Task.checkCancellation()
            let drained = router.drainBufferedNotifications()
            if !drained.isEmpty {
                return drained
            }
            await Task.yield()
        }
    }
}
