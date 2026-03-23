import AppKit
import ApplicationServices
import Foundation
import Logging
import ProxyCore

package enum XcodePermissionDialogAccessibilityStatus: Sendable {
    case trusted
    case untrusted
}

package struct XcodePermissionDialogWindowSnapshot: Equatable, Sendable {
    package let title: String
    package let textValues: [String]
    package let isModal: Bool
    package let defaultButtonTitle: String?
    package let cancelButtonTitle: String?

    package init(
        title: String,
        textValues: [String],
        isModal: Bool,
        defaultButtonTitle: String?,
        cancelButtonTitle: String?
    ) {
        self.title = title
        self.textValues = textValues
        self.isModal = isModal
        self.defaultButtonTitle = defaultButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
    }
}

package struct XcodePermissionDialogMatchDecision: Equatable, Sendable {
    package let fingerprint: String
    package let defaultButtonTitle: String

    package init(fingerprint: String, defaultButtonTitle: String) {
        self.fingerprint = fingerprint
        self.defaultButtonTitle = defaultButtonTitle
    }
}

package enum XcodePermissionDialogMatcher {
    package static func decision(
        for snapshot: XcodePermissionDialogWindowSnapshot,
        processID: pid_t,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>
    ) -> XcodePermissionDialogMatchDecision? {
        guard snapshot.isModal else {
            return nil
        }

        guard
            let defaultButtonTitle = normalizedText(snapshot.defaultButtonTitle)
        else {
            return nil
        }

        let haystacks = normalizedHaystacks(for: snapshot)
        guard haystacks.contains(where: { $0.contains("xcode") }) else {
            return nil
        }

        let normalizedCandidates = normalizedAgentPathCandidates(agentPathCandidates)
        let normalizedAssistantNames = normalizedAgentPathCandidates(assistantNameCandidates)
        guard normalizedCandidates.isEmpty == false || normalizedAssistantNames.isEmpty == false else {
            return nil
        }

        let containsPath = haystacks.contains { haystack in
            normalizedCandidates.contains { candidate in
                haystack.contains(candidate)
            }
        }
        let containsAssistantName = haystacks.contains { haystack in
            normalizedAssistantNames.contains { candidate in
                haystack.contains(candidate)
            }
        }
        guard containsPath || containsAssistantName else {
            return nil
        }

        return XcodePermissionDialogMatchDecision(
            fingerprint: fingerprint(for: snapshot, processID: processID),
            defaultButtonTitle: defaultButtonTitle
        )
    }

    package static func fingerprint(
        for snapshot: XcodePermissionDialogWindowSnapshot,
        processID: pid_t
    ) -> String {
        let textFingerprint = normalizedHaystacks(for: snapshot).joined(separator: "\u{1F}")
        return "\(processID)|\(snapshot.isModal)|\(textFingerprint)"
    }

    package static func normalizedAgentPathCandidates(_ candidates: Set<String>) -> Set<String> {
        Set(candidates.compactMap(normalizedText))
    }

    private static func normalizedHaystacks(for snapshot: XcodePermissionDialogWindowSnapshot) -> [String] {
        ([snapshot.title] + snapshot.textValues).compactMap(normalizedText)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let sanitizedScalars = text.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .format
        }
        let sanitized = String(String.UnicodeScalarView(sanitizedScalars))
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed.lowercased()
    }
}

package protocol XcodePermissionDialogAXAccessing: Sendable {
    func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAccessibilityStatus
    func runningXcodeProcessIDs() -> [pid_t]
    func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAXWindow]
    func pressDefaultButton(in window: XcodePermissionDialogAXWindow) throws
}

package final class XcodePermissionDialogAXWindow {
    package let processID: pid_t
    package let snapshot: XcodePermissionDialogWindowSnapshot
    private let defaultButton: AXUIElement

    package init(
        processID: pid_t,
        snapshot: XcodePermissionDialogWindowSnapshot,
        defaultButton: AXUIElement
    ) {
        self.processID = processID
        self.snapshot = snapshot
        self.defaultButton = defaultButton
    }

    fileprivate func pressDefaultButton() throws {
        let error = AXUIElementPerformAction(defaultButton, kAXPressAction as CFString)
        guard error == .success else {
            throw XcodePermissionDialogAXError.performActionFailed(error)
        }
    }
}

package enum XcodePermissionDialogAXError: Error, CustomStringConvertible {
    case copyAttributeFailed(attribute: String, error: AXError)
    case performActionFailed(AXError)

    package var description: String {
        switch self {
        case .copyAttributeFailed(let attribute, let error):
            return "AX attribute '\(attribute)' failed: \(error.rawValue)"
        case .performActionFailed(let error):
            return "AX action failed: \(error.rawValue)"
        }
    }
}

package struct LiveXcodePermissionDialogAXClient: XcodePermissionDialogAXAccessing {
    private let maxDescendantCount = 128

    package init() {}

    package func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAccessibilityStatus {
        if promptIfNeeded {
            let options: NSDictionary = [
                "AXTrustedCheckOptionPrompt" as NSString: true
            ]
            return AXIsProcessTrustedWithOptions(options) ? .trusted : .untrusted
        }
        return AXIsProcessTrusted() ? .trusted : .untrusted
    }

    package func runningXcodeProcessIDs() -> [pid_t] {
        let bundleIdentifiers: Set<String> = [
            "com.apple.dt.Xcode",
            "com.apple.dt.ExternalViewService",
        ]
        let processIDs = NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return nil
            }
            guard bundleIdentifiers.contains(bundleIdentifier), application.isTerminated == false else {
                return nil
            }
            return application.processIdentifier
        }
        return Array(Set(processIDs)).sorted()
    }

    package func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAXWindow] {
        let app = AXUIElementCreateApplication(processID)
        return try copyElementArray(attribute: kAXWindowsAttribute as CFString, from: app).compactMap { window in
            try makeWindow(processID: processID, window: window)
        }
    }

    package func pressDefaultButton(in window: XcodePermissionDialogAXWindow) throws {
        try window.pressDefaultButton()
    }

    private func makeWindow(
        processID: pid_t,
        window: AXUIElement
    ) throws -> XcodePermissionDialogAXWindow? {
        guard let defaultButton = copyElement(attribute: kAXDefaultButtonAttribute as CFString, from: window) else {
            return nil
        }

        let snapshot = XcodePermissionDialogWindowSnapshot(
            title: copyString(attribute: kAXTitleAttribute as CFString, from: window) ?? "",
            textValues: collectTextValues(from: window),
            isModal: copyBool(attribute: kAXModalAttribute as CFString, from: window) ?? false,
            defaultButtonTitle: copyButtonLabel(from: defaultButton),
            cancelButtonTitle: copyElement(attribute: kAXCancelButtonAttribute as CFString, from: window)
                .flatMap(copyButtonLabel(from:))
        )

        return XcodePermissionDialogAXWindow(
            processID: processID,
            snapshot: snapshot,
            defaultButton: defaultButton
        )
    }

    private func collectTextValues(from root: AXUIElement) -> [String] {
        var queue: [AXUIElement] = [root]
        var values: [String] = []
        var visited = 0

        while queue.isEmpty == false, visited < maxDescendantCount {
            let element = queue.removeFirst()
            visited += 1

            if let title = copyString(attribute: kAXTitleAttribute as CFString, from: element) {
                values.append(title)
            }
            if let value = copyString(attribute: kAXValueAttribute as CFString, from: element) {
                values.append(value)
            }
            if let description = copyString(attribute: kAXDescriptionAttribute as CFString, from: element) {
                values.append(description)
            }

            if let children = try? copyElementArray(attribute: kAXChildrenAttribute as CFString, from: element) {
                queue.append(contentsOf: children)
            }
        }

        var seen = Set<String>()
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                return false
            }
            return seen.insert(trimmed).inserted
        }
    }

    private func copyButtonLabel(from element: AXUIElement) -> String? {
        copyString(attribute: kAXTitleAttribute as CFString, from: element)
            ?? copyString(attribute: kAXDescriptionAttribute as CFString, from: element)
            ?? copyString(attribute: kAXValueAttribute as CFString, from: element)
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = try? copyAttribute(attribute: attribute, from: element) else {
            return nil
        }
        return value as? String
    }

    private func copyBool(attribute: CFString, from element: AXUIElement) -> Bool? {
        guard let value = try? copyAttribute(attribute: attribute, from: element) else {
            return nil
        }
        return value as? Bool
    }

    private func copyElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = try? copyAttribute(attribute: attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafe unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyElementArray(attribute: CFString, from element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try copyAttribute(attribute: attribute, from: element) else {
            return []
        }
        if let elements = value as? [AXUIElement] {
            return elements
        }
        if let array = value as? [AnyObject] {
            return array.compactMap { candidate in
                guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
                    return nil
                }
                return unsafe unsafeDowncast(candidate, to: AXUIElement.self)
            }
        }
        return []
    }

    private func copyAttribute(attribute: CFString, from element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .success, .noValue:
            return value
        default:
            throw XcodePermissionDialogAXError.copyAttributeFailed(
                attribute: attribute as String,
                error: error
            )
        }
    }
}

package final class XcodePermissionDialogAutoApprover: @unchecked Sendable {
    package struct Dependencies: Sendable {
        package var axClient: any XcodePermissionDialogAXAccessing
        package var agentPathCandidates: @Sendable () -> Set<String>
        package var assistantNameCandidates: @Sendable () -> Set<String>
        package var sleep: @Sendable (Duration) async -> Void
        package var pollInterval: Duration
        package var logger: Logger

        package init(
            axClient: any XcodePermissionDialogAXAccessing,
            agentPathCandidates: @escaping @Sendable () -> Set<String>,
            assistantNameCandidates: @escaping @Sendable () -> Set<String>,
            sleep: @escaping @Sendable (Duration) async -> Void,
            pollInterval: Duration,
            logger: Logger
        ) {
            self.axClient = axClient
            self.agentPathCandidates = agentPathCandidates
            self.assistantNameCandidates = assistantNameCandidates
            self.sleep = sleep
            self.pollInterval = pollInterval
            self.logger = logger
        }

        package static func live(
            agentPathCandidates: @escaping @Sendable () -> Set<String> = {
                XcodePermissionDialogAutoApprover.defaultAgentPathCandidates()
            },
            assistantNameCandidates: @escaping @Sendable () -> Set<String> = {
                []
            }
        ) -> Self {
            Self(
                axClient: LiveXcodePermissionDialogAXClient(),
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                sleep: { duration in
                    try? await Task.sleep(for: duration)
                },
                pollInterval: .milliseconds(250),
                logger: ProxyLogging.make("xcode.permission")
            )
        }
    }

    private struct State {
        var started = false
        var task: Task<Void, Never>?
        var lastAttemptUptimeByFingerprint: [String: UInt64] = [:]
        var didLogNoMatch = false
    }

    private let dependencies: Dependencies
    private let stateLock = NSLock()
    private var state = State()
    private let retryIntervalNanoseconds: UInt64 = 500_000_000

    package init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    package func start() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state.started == false else {
            return
        }
        state.started = true

        switch dependencies.axClient.authorizationStatus(promptIfNeeded: false) {
        case .trusted:
            let task = Task { [dependencies, weak self] in
                guard let self else {
                    return
                }
                await self.runMonitorLoop(dependencies: dependencies)
            }
            state.task = task
        case .untrusted:
            _ = dependencies.axClient.authorizationStatus(promptIfNeeded: true)
            dependencies.logger.warning(
                "Accessibility permission is required to auto-approve the Xcode permission dialog; requested the system prompt and will keep waiting for permission."
            )
            let task = Task { [dependencies, weak self] in
                guard let self else {
                    return
                }
                await self.runMonitorLoop(dependencies: dependencies)
            }
            state.task = task
        }
    }

    package func stop() {
        let task: Task<Void, Never>? = stateLock.withLock {
            state.started = false
            state.lastAttemptUptimeByFingerprint.removeAll()
            let task = state.task
            state.task = nil
            return task
        }

        task?.cancel()
    }

    package static func defaultAgentPathCandidates(
        arguments: [String] = CommandLine.arguments,
        executableURL: URL? = Bundle.main.executableURL,
        additionalExecutableCandidates: [String] = []
    ) -> Set<String> {
        var candidates: Set<String> = []

        if let raw = arguments.first, raw.isEmpty == false {
            candidates.insert(raw)
            let rawURL = URL(fileURLWithPath: raw)
            candidates.insert(rawURL.standardizedFileURL.path)
            candidates.insert(rawURL.resolvingSymlinksInPath().path)
        }

        if let executablePath = executableURL?.path, executablePath.isEmpty == false {
            let executableURL = URL(fileURLWithPath: executablePath)
            candidates.insert(executablePath)
            candidates.insert(executableURL.standardizedFileURL.path)
            candidates.insert(executableURL.resolvingSymlinksInPath().path)
        }

        for candidate in additionalExecutableCandidates where candidate.isEmpty == false {
            let candidateURL = URL(fileURLWithPath: candidate)
            candidates.insert(candidate)
            candidates.insert(candidateURL.standardizedFileURL.path)
            candidates.insert(candidateURL.resolvingSymlinksInPath().path)
        }

        return Set(candidates.filter { $0.isEmpty == false })
    }

    private func runMonitorLoop(dependencies: Dependencies) async {
        let agentPathCandidates = dependencies.agentPathCandidates()
        let assistantNameCandidates = dependencies.assistantNameCandidates()
        let pathCandidateText = agentPathCandidates.sorted().joined(separator: " | ")
        var hasLoggedTrustedMonitoring = false

        while Task.isCancelled == false {
            if dependencies.axClient.authorizationStatus(promptIfNeeded: false) != .trusted {
                await dependencies.sleep(dependencies.pollInterval)
                continue
            }

            if hasLoggedTrustedMonitoring == false {
                dependencies.logger.info(
                    "Xcode permission dialog auto-approver is monitoring Xcode.",
                    metadata: [
                        "agent_paths": .string(pathCandidateText)
                    ]
                )
                hasLoggedTrustedMonitoring = true
            }

            let visibleFingerprints = scanAndApprove(
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                dependencies: dependencies
            )
            stateLock.withLock {
                state.lastAttemptUptimeByFingerprint =
                    state.lastAttemptUptimeByFingerprint.filter { visibleFingerprints.contains($0.key) }
            }

            await dependencies.sleep(dependencies.pollInterval)
        }
    }

    private func scanAndApprove(
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        dependencies: Dependencies
    ) -> Set<String> {
        var visibleFingerprints: Set<String> = []
        var inspectedWindowTitles: [String] = []
        let processIDs = dependencies.axClient.runningXcodeProcessIDs()
        let nowUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        for processID in processIDs {
            let windows: [XcodePermissionDialogAXWindow]
            do {
                windows = try dependencies.axClient.openWindows(for: processID)
            } catch {
                dependencies.logger.warning(
                    "Failed to inspect AX windows for a running Xcode-related process.",
                    metadata: [
                        "pid": "\(processID)",
                        "error": "\(error)",
                    ]
                )
                continue
            }
            for window in windows {
                let trimmedTitle = window.snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty == false, inspectedWindowTitles.count < 8 {
                    inspectedWindowTitles.append(trimmedTitle)
                }
                guard let decision = XcodePermissionDialogMatcher.decision(
                    for: window.snapshot,
                    processID: processID,
                    agentPathCandidates: agentPathCandidates,
                    assistantNameCandidates: assistantNameCandidates
                ) else {
                    continue
                }

                visibleFingerprints.insert(decision.fingerprint)

                let shouldPress = stateLock.withLock { () -> Bool in
                    if let lastAttempt = state.lastAttemptUptimeByFingerprint[decision.fingerprint],
                       nowUptimeNanoseconds &- lastAttempt < retryIntervalNanoseconds
                    {
                        return false
                    }
                    state.lastAttemptUptimeByFingerprint[decision.fingerprint] = nowUptimeNanoseconds
                    return true
                }
                guard shouldPress else {
                    continue
                }

                do {
                    try dependencies.axClient.pressDefaultButton(in: window)
                    dependencies.logger.info(
                        "Auto-approved the Xcode permission dialog.",
                        metadata: [
                            "pid": "\(processID)",
                            "button": .string(decision.defaultButtonTitle),
                        ]
                    )
                } catch {
                    dependencies.logger.warning(
                        "Matched the Xcode permission dialog but could not press its default button.",
                        metadata: [
                            "pid": "\(processID)",
                            "error": "\(error)",
                        ]
                    )
                }
            }
        }

        let shouldLogNoMatch = stateLock.withLock { () -> Bool in
            if visibleFingerprints.isEmpty == false {
                state.didLogNoMatch = false
                return false
            }
            guard processIDs.isEmpty == false, state.didLogNoMatch == false else {
                return false
            }
            state.didLogNoMatch = true
            return true
        }
        if shouldLogNoMatch {
            dependencies.logger.debug(
                "Xcode permission dialog auto-approver found running Xcode windows but no matching permission dialog yet.",
                metadata: [
                    "xcode_pids": .string(processIDs.map(String.init).joined(separator: ",")),
                    "window_titles": .string(inspectedWindowTitles.joined(separator: " | ")),
                ]
            )
        }

        return visibleFingerprints
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
