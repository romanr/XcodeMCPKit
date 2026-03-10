import Foundation
import NIOEmbedded
import Testing

@testable import XcodeMCPProxy

@Suite
struct XcodeEditorWarmupDriverTests {
    @Test func warmupDriverResolvesDirectPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("App/Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "App/Sources/Foo.swift"
        )

        #expect(resolved == target.path)
    }

    @Test func warmupDriverResolvesSuffixMatchedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/TimeLine/View/Regular/RegularTimelineView.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift"
        )

        #expect(resolved?.lowercased() == target.path.lowercased())
    }

    @Test func warmupDriverReturnsNilForAmbiguousSuffixMatchedPath() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let candidates = [
            "A/Timeline/View/Foo.swift",
            "B/Timeline/View/Foo.swift",
        ]
        for relativePath in candidates {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "".write(to: url, atomically: true, encoding: .utf8)
        }

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Timeline/View/Foo.swift"
        )

        #expect(resolved == nil)
    }

    @Test func warmupDriverRejectsAbsolutePathOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: outsideFile.path
        )

        #expect(resolved == nil)
    }

    @Test func warmupDriverRejectsTraversalOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "../Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func warmupDriverRejectsSymlinkEscapeOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkPath = URL(fileURLWithPath: root).appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: outsideRoot
        )

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "linked/Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func warmupDriverRejectsSuffixMatchedSymlinkEscapeOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let outsideFile = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("Outside.swift")
        try "".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkDirectory = URL(fileURLWithPath: root)
            .appendingPathComponent("Some")
            .path
        try FileManager.default.createDirectory(atPath: symlinkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: URL(fileURLWithPath: symlinkDirectory).appendingPathComponent("Outside.swift").path,
            withDestinationPath: outsideFile.path
        )

        let driver = XcodeEditorWarmupDriver(isEnabled: false)
        let resolved = await driver.resolveAbsoluteFilePath(
            workspacePath: root,
            workspaceRoot: root,
            requestedFilePath: "Nested/Outside.swift"
        )

        #expect(resolved == nil)
    }

    @Test func warmupDriverWarmsAndRestoresUsingProcessRunner() async throws {
        let root = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )
        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/TimeLine/View/Regular/RegularTimelineView.swift")
        let restorePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/Store/AccountStore.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: restorePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)
        try "".write(to: restorePath, atomically: true, encoding: .utf8)

        let runner = FakeProcessRunner()
        await runner.enqueue(
            label: "window-title",
            stdout: "tweetpd — AccountStore.swift\n"
        )
        await runner.enqueue(
            label: "source-document-paths",
            stdout: "\(restorePath.path)\n"
        )
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")
        await runner.enqueue(label: "window-title", stdout: "tweetpd — RegularTimelineView.swift\n")
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")

        let driver = XcodeEditorWarmupDriver(processRunner: runner)
        let eventLoop = EmbeddedEventLoop()
        let result = await driver.warmUp(
            tabIdentifier: "windowtab2",
            filePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift",
            sessionId: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )

        #expect(result.context?.resolvedFilePath.lowercased() == target.path.lowercased())
        #expect(result.snapshot?.visibleSourceBasename == "AccountStore.swift")

        let restoreResult = await driver.restore(result.context)
        #expect(restoreResult == "restored")

        let requests = await runner.requests()
        #expect(requests.map(\.label) == [
            "window-title",
            "source-document-paths",
            "open-source-document",
            "touch-source-document",
            "window-title",
            "open-source-document",
            "touch-source-document",
        ])
    }

    @Test func warmupDriverSnapshotExcludesPathsOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = root + "-backup"
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )
        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/Timeline/View/Regular/RegularTimelineView.swift")
        let insideRestorePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/Store/AccountStore.swift")
        let outsideRestorePath = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("tweetpd/Store/AccountStore.swift")

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: insideRestorePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRestorePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)
        try "".write(to: insideRestorePath, atomically: true, encoding: .utf8)
        try "".write(to: outsideRestorePath, atomically: true, encoding: .utf8)

        let runner = FakeProcessRunner()
        await runner.enqueue(
            label: "window-title",
            stdout: "tweetpd — AccountStore.swift\n"
        )
        await runner.enqueue(
            label: "source-document-paths",
            stdout: "\(insideRestorePath.path)\n\(outsideRestorePath.path)\n"
        )
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")
        await runner.enqueue(label: "window-title", stdout: "tweetpd — RegularTimelineView.swift\n")
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")

        let driver = XcodeEditorWarmupDriver(processRunner: runner)
        let eventLoop = EmbeddedEventLoop()
        let result = await driver.warmUp(
            tabIdentifier: "windowtab2",
            filePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift",
            sessionId: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )

        #expect(result.snapshot?.candidateSourceDocumentPaths == [insideRestorePath.path])

        let restoreResult = await driver.restore(result.context)
        #expect(restoreResult == "restored")
    }

    @Test func warmupDriverSnapshotExcludesSymlinkEscapesOutsideWorkspaceRoot() async throws {
        let root = makeTemporaryWorkspaceRoot()
        let outsideRoot = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }

        let workspacePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let target = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/Timeline/View/Regular/RegularTimelineView.swift")
        let insideRestorePath = URL(fileURLWithPath: root)
            .appendingPathComponent("tweetpd/Store/AccountStore.swift")
        let symlinkPath = URL(fileURLWithPath: root).appendingPathComponent("linked").path
        let outsideRestorePath = URL(fileURLWithPath: outsideRoot)
            .appendingPathComponent("AccountStore.swift")

        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: insideRestorePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)
        try "".write(to: insideRestorePath, atomically: true, encoding: .utf8)
        try "".write(to: outsideRestorePath, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath,
            withDestinationPath: outsideRoot
        )

        let runner = FakeProcessRunner()
        await runner.enqueue(
            label: "window-title",
            stdout: "tweetpd — AccountStore.swift\n"
        )
        await runner.enqueue(
            label: "source-document-paths",
            stdout: "\(insideRestorePath.path)\n\(symlinkPath)/AccountStore.swift\n"
        )
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")
        await runner.enqueue(label: "window-title", stdout: "tweetpd — RegularTimelineView.swift\n")
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")

        let driver = XcodeEditorWarmupDriver(processRunner: runner)
        let eventLoop = EmbeddedEventLoop()
        let result = await driver.warmUp(
            tabIdentifier: "windowtab2",
            filePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift",
            sessionId: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspacePath)]
            }
        )

        #expect(result.snapshot?.candidateSourceDocumentPaths == [insideRestorePath.path])
    }

    @Test func warmupDriverRevalidatesCachedWorkspacePath() async throws {
        let rootA = makeTemporaryWorkspaceRoot()
        let rootB = makeTemporaryWorkspaceRoot()
        defer {
            try? FileManager.default.removeItem(atPath: rootA)
            try? FileManager.default.removeItem(atPath: rootB)
        }

        let workspaceA = URL(fileURLWithPath: rootA)
            .appendingPathComponent("tweetpd.xcworkspace").path
        let workspaceB = URL(fileURLWithPath: rootB)
            .appendingPathComponent("tweetpd.xcworkspace").path
        try FileManager.default.createDirectory(atPath: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspaceB, withIntermediateDirectories: true)

        let targetA = URL(fileURLWithPath: rootA)
            .appendingPathComponent("tweetpd/Timeline/View/Regular/RegularTimelineView.swift")
        let targetB = URL(fileURLWithPath: rootB)
            .appendingPathComponent("tweetpd/Timeline/View/Regular/RegularTimelineView.swift")
        try FileManager.default.createDirectory(
            at: targetA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: targetB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: targetA, atomically: true, encoding: .utf8)
        try "".write(to: targetB, atomically: true, encoding: .utf8)

        let runner = FakeProcessRunner()
        await runner.enqueue(label: "window-title", stdout: "tweetpd — RegularTimelineView.swift\n")
        await runner.enqueue(label: "source-document-paths", stdout: "\(targetA.path)\n")
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")
        await runner.enqueue(label: "window-title", stdout: "tweetpd — RegularTimelineView.swift\n")
        await runner.enqueue(label: "source-document-paths", stdout: "\(targetB.path)\n")
        await runner.enqueue(label: "open-source-document", stdout: "ok\n")
        await runner.enqueue(label: "touch-source-document", stdout: "ready\n")

        let driver = XcodeEditorWarmupDriver(processRunner: runner)
        let eventLoop = EmbeddedEventLoop()

        let first = await driver.warmUp(
            tabIdentifier: "windowtab2",
            filePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift",
            sessionId: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspaceA)]
            }
        )
        let second = await driver.warmUp(
            tabIdentifier: "windowtab2",
            filePath: "tweetpd/Timeline/View/Regular/RegularTimelineView.swift",
            sessionId: "session-1",
            eventLoop: eventLoop,
            windowsProvider: { _, _ in
                [XcodeWindowInfo(tabIdentifier: "windowtab2", workspacePath: workspaceB)]
            }
        )

        #expect(first.workspacePath == workspaceA)
        #expect(second.workspacePath == workspaceB)
        #expect(second.context?.resolvedFilePath == targetB.path)
    }

    @Test func warmupDriverRestoreSkipsAmbiguousCandidate() async throws {
        let runner = FakeProcessRunner()
        let driver = XcodeEditorWarmupDriver(processRunner: runner)
        let context = WarmupContext(
            workspacePath: "/tmp/workspace",
            workspaceRoot: "/tmp/workspace",
            resolvedFilePath: "/tmp/workspace/Target/Foo.swift",
            snapshot: EditorSnapshot(
                workspacePath: "/tmp/workspace",
                workspaceRoot: "/tmp/workspace",
                windowTitle: "tweetpd — Foo.swift",
                candidateSourceDocumentPaths: [
                    "/tmp/workspace/A/Foo.swift",
                    "/tmp/workspace/B/Foo.swift",
                ],
                visibleSourceBasename: "Foo.swift"
            )
        )

        await runner.enqueue(label: "window-title", stdout: "tweetpd — Foo.swift\n")
        let restoreResult = await driver.restore(context)
        #expect(restoreResult == "restore_candidate_ambiguous")
        #expect(await runner.requests().map(\.label) == ["window-title"])
    }
}

private actor FakeProcessRunner: ProcessRunning {
    private struct PlannedOutput {
        let label: String
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private var plannedOutputs: [PlannedOutput] = []
    private var capturedRequests: [ProcessRequest] = []

    func enqueue(
        label: String,
        stdout: String = "",
        stderr: String = "",
        terminationStatus: Int32 = 0
    ) {
        plannedOutputs.append(
            PlannedOutput(
                label: label,
                stdout: stdout,
                stderr: stderr,
                terminationStatus: terminationStatus
            )
        )
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        capturedRequests.append(request)
        guard plannedOutputs.isEmpty == false else {
            return ProcessOutput(terminationStatus: 1, stdout: "", stderr: "no output")
        }
        let next = plannedOutputs.removeFirst()
        #expect(next.label == request.label)
        return ProcessOutput(
            terminationStatus: next.terminationStatus,
            stdout: next.stdout,
            stderr: next.stderr
        )
    }

    func requests() -> [ProcessRequest] {
        capturedRequests
    }
}

private func makeTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
