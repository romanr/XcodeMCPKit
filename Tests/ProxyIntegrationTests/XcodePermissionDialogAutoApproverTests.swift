import Foundation
import Testing

@testable import ProxyCore
@testable import ProxyFeatureXcode

@Suite(.serialized)
struct XcodePermissionDialogAutoApproverTests {
    @Test func matcherRecognizesXcodePermissionDialogAndChoosesDefaultButton() {
        let snapshot = XcodePermissionDialogWindowSnapshot(
            title: "Allow “XcodeMCPKit” to access Xcode?",
            textValues: [
                "The agent “XcodeMCPKit” at /tmp/xcode-mcp-proxy-server wants to use Xcode's tools."
            ],
            isModal: true,
            defaultButtonTitle: "Allow",
            cancelButtonTitle: "Don't Allow"
        )

        let decision = XcodePermissionDialogMatcher.decision(
            for: snapshot,
            processID: 6119,
            agentPathCandidates: ["/tmp/xcode-mcp-proxy-server"],
            assistantNameCandidates: []
        )

        #expect(decision?.defaultButtonTitle == "allow")
        #expect(decision?.fingerprint.isEmpty == false)
    }

    @Test func matcherRecognizesDialogWhenPathContainsFormatCharactersAndCancelButtonIsUnavailable() {
        let snapshot = XcodePermissionDialogWindowSnapshot(
            title: "",
            textValues: [
                "Allow “XcodeMCPKit” to access Xcode?",
                "The agent “XcodeMCPKit” at /\u{200B}tmp/\u{200B}build/\u{200B}xcode-mcp-proxy-server wants to use Xcode's tools."
            ],
            isModal: true,
            defaultButtonTitle: "Allow",
            cancelButtonTitle: nil
        )

        let decision = XcodePermissionDialogMatcher.decision(
            for: snapshot,
            processID: 4317,
            agentPathCandidates: ["/tmp/build/xcode-mcp-proxy-server"],
            assistantNameCandidates: []
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherRecognizesDialogFromAssistantNameWhenExecutablePathIsUnavailable() {
        let snapshot = XcodePermissionDialogWindowSnapshot(
            title: "Allow “XcodeMCPKit” to access Xcode?",
            textValues: [
                "The agent “XcodeMCPKit” wants to use Xcode's tools."
            ],
            isModal: true,
            defaultButtonTitle: "Allow",
            cancelButtonTitle: nil
        )

        let decision = XcodePermissionDialogMatcher.decision(
            for: snapshot,
            processID: 4317,
            agentPathCandidates: [],
            assistantNameCandidates: ["XcodeMCPKit"]
        )

        #expect(decision?.defaultButtonTitle == "allow")
    }

    @Test func matcherIgnoresUnrelatedXcodeDialogWithoutAgentPath() {
        let snapshot = XcodePermissionDialogWindowSnapshot(
            title: "Xcode",
            textValues: [
                "A build destination could not be found."
            ],
            isModal: true,
            defaultButtonTitle: "OK",
            cancelButtonTitle: "Cancel"
        )

        let decision = XcodePermissionDialogMatcher.decision(
            for: snapshot,
            processID: 42,
            agentPathCandidates: ["/tmp/xcode-mcp-proxy-server"],
            assistantNameCandidates: []
        )

        #expect(decision == nil)
    }

    @Test func defaultAgentPathCandidatesIncludeRawAndResolvedExecutablePaths() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("xcode-mcp-auto-approver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let realExecutable = temporaryDirectory.appendingPathComponent("real-server")
        #expect(fileManager.createFile(atPath: realExecutable.path, contents: Data()))
        let symlinkExecutable = temporaryDirectory.appendingPathComponent("link-server")
        try fileManager.createSymbolicLink(at: symlinkExecutable, withDestinationURL: realExecutable)

        let candidates = XcodePermissionDialogAutoApprover.defaultAgentPathCandidates(
            arguments: [symlinkExecutable.path],
            executableURL: realExecutable
        )

        #expect(candidates.contains(symlinkExecutable.path))
        #expect(candidates.contains(realExecutable.path))
    }

    @Test func autoApproverPromptsAccessibilityOnceAndRemainsInactiveWhenUntrusted() async {
        let axClient = RecordingAXClient(status: .untrusted)
        let approver = XcodePermissionDialogAutoApprover(
            dependencies: .init(
                axClient: axClient,
                agentPathCandidates: { ["/tmp/xcode-mcp-proxy-server"] },
                assistantNameCandidates: { ["XcodeMCPKit"] },
                sleep: { _ in },
                pollInterval: .milliseconds(1),
                logger: ProxyLogging.make("tests.permission")
            )
        )

        approver.start()
        approver.start()
        approver.stop()

        let snapshot = axClient.snapshot()
        #expect(snapshot.promptCalls == 1)
        #expect(snapshot.windowScanCalls == 0)
    }
}

private final class RecordingAXClient: @unchecked Sendable, XcodePermissionDialogAXAccessing {
    private let status: XcodePermissionDialogAccessibilityStatus
    private let lock = NSLock()
    private var promptCalls = 0
    private var windowScanCalls = 0

    init(status: XcodePermissionDialogAccessibilityStatus) {
        self.status = status
    }

    func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAccessibilityStatus {
        lock.withLock {
            if promptIfNeeded {
                promptCalls += 1
            }
            return status
        }
    }

    func runningXcodeProcessIDs() -> [pid_t] {
        lock.withLock {
            windowScanCalls += 1
            return []
        }
    }

    func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAXWindow] {
        []
    }

    func pressDefaultButton(in window: XcodePermissionDialogAXWindow) throws {}

    func snapshot() -> (promptCalls: Int, windowScanCalls: Int) {
        lock.withLock {
            (promptCalls, windowScanCalls)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
