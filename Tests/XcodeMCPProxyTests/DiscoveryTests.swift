import Foundation
import Testing

@testable import XcodeMCPProxy

private func makeTempDiscoveryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("endpoint.json")
}

private func cleanupTempDiscoveryURL(_ url: URL) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: directory)
}

@Suite
struct DiscoveryTests {
    @Test func discoveryRoundTrip() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://localhost:7777/mcp",
            host: "localhost",
            port: 7777,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        let loaded = Discovery.read(overrideURL: url)
        #expect(loaded?.url == record.url)
        #expect(loaded?.host == record.host)
        #expect(loaded?.port == record.port)
        #expect(loaded?.pid == record.pid)
    }

    @Test func discoveryIgnoresInvalidJSON() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(Discovery.read(overrideURL: url) == nil)
    }

    @Test func discoveryRejectsDeadPid() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://localhost:8888/mcp",
            host: "localhost",
            port: 8888,
            pid: 0,
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url) == nil)
    }

    @Test func discoveryFormatsIPv6Host() async throws {
        let record = Discovery.makeRecord(host: "::1", port: 1234, pid: 1)
        #expect(record?.url == "http://[::1]:1234/mcp")
    }
}
