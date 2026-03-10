import Foundation
import Logging
import NIO

struct XcodeWindowInfo: Sendable, Equatable {
    let tabIdentifier: String
    let workspacePath: String
}

struct EditorSnapshot: Sendable, Equatable {
    let workspacePath: String
    let workspaceRoot: String
    let windowTitle: String
    let candidateSourceDocumentPaths: [String]
    let visibleSourceBasename: String?
}

struct WarmupContext: Sendable, Equatable {
    let workspacePath: String
    let workspaceRoot: String
    let resolvedFilePath: String
    let snapshot: EditorSnapshot?
}

struct WarmupResult: Sendable, Equatable {
    let context: WarmupContext?
    let snapshot: EditorSnapshot?
    let workspacePath: String?
    let resolvedFilePath: String?
    let failureReason: String?
}

actor XcodeEditorWarmupDriver {
    typealias WindowsProvider = @Sendable (_ sessionId: String, _ eventLoop: EventLoop) async -> [XcodeWindowInfo]?

    private struct FileResolutionKey: Hashable {
        let workspacePath: String
        let filePath: String
    }

    private let processRunner: any ProcessRunning
    private let fileManager = FileManager.default
    private let logger: Logger
    private let isEnabled: Bool

    private var workspacePathCache: [String: String] = [:]
    private var resolvedFilePathCache: [FileResolutionKey: String] = [:]

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        logger: Logger = ProxyLogging.make("warmup"),
        isEnabled: Bool = true
    ) {
        self.processRunner = processRunner
        self.logger = logger
        self.isEnabled = isEnabled
    }

    static func disabled() -> XcodeEditorWarmupDriver {
        XcodeEditorWarmupDriver(isEnabled: false)
    }

    func warmUp(
        tabIdentifier: String?,
        filePath: String?,
        sessionId: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async -> WarmupResult {
        guard isEnabled else {
            return WarmupResult(
                context: nil,
                snapshot: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "disabled"
            )
        }
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return WarmupResult(
                context: nil,
                snapshot: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing tabIdentifier"
            )
        }
        guard let filePath, filePath.isEmpty == false else {
            return WarmupResult(
                context: nil,
                snapshot: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "missing filePath"
            )
        }

        let workspacePath = await resolveWorkspacePath(
            tabIdentifier: tabIdentifier,
            sessionId: sessionId,
            eventLoop: eventLoop,
            windowsProvider: windowsProvider
        )
        guard let workspacePath else {
            return WarmupResult(
                context: nil,
                snapshot: nil,
                workspacePath: nil,
                resolvedFilePath: nil,
                failureReason: "workspacePath not found"
            )
        }

        let workspaceRoot = workspaceRoot(for: workspacePath)
        let resolvedFilePath = resolveAbsoluteFilePath(
            workspacePath: workspacePath,
            workspaceRoot: workspaceRoot,
            requestedFilePath: filePath
        )

        let snapshot = await editorSnapshot(
            workspacePath: workspacePath,
            workspaceRoot: workspaceRoot
        )

        guard let resolvedFilePath else {
            return WarmupResult(
                context: nil,
                snapshot: snapshot,
                workspacePath: workspacePath,
                resolvedFilePath: nil,
                failureReason: "could not resolve target path"
            )
        }

        let opened = await openSourceDocument(
            at: resolvedFilePath,
            workspacePath: workspacePath
        )
        guard opened else {
            return WarmupResult(
                context: nil,
                snapshot: snapshot,
                workspacePath: workspacePath,
                resolvedFilePath: resolvedFilePath,
                failureReason: "could not open source document"
            )
        }

        let touched = await ensureSourceDocumentVisible(
            at: resolvedFilePath,
            workspacePath: workspacePath
        )
        guard touched else {
            return WarmupResult(
                context: nil,
                snapshot: snapshot,
                workspacePath: workspacePath,
                resolvedFilePath: resolvedFilePath,
                failureReason: "could not activate source document"
            )
        }

        return WarmupResult(
            context: WarmupContext(
                workspacePath: workspacePath,
                workspaceRoot: workspaceRoot,
                resolvedFilePath: resolvedFilePath,
                snapshot: snapshot
            ),
            snapshot: snapshot,
            workspacePath: workspacePath,
            resolvedFilePath: resolvedFilePath,
            failureReason: nil
        )
    }

    func touchResolvedTarget(_ context: WarmupContext) async -> Bool {
        guard isEnabled else { return false }
        return await ensureSourceDocumentVisible(
            at: context.resolvedFilePath,
            workspacePath: context.workspacePath
        )
    }

    @discardableResult
    func restore(_ context: WarmupContext?) async -> String {
        guard isEnabled else { return "disabled" }
        guard let context else { return "no_context" }
        let snapshot = context.snapshot
        guard let snapshot else { return "no_snapshot" }
        let currentVisibleBasename = await windowTitle(for: snapshot.workspacePath)
            .flatMap { visibleSourceBasename(from: $0) }
        let targetBasename = URL(fileURLWithPath: context.resolvedFilePath).lastPathComponent
        if let currentVisibleBasename, currentVisibleBasename != targetBasename {
            return "restore_skipped_user_navigation"
        }
        guard let basename = snapshot.visibleSourceBasename, basename.isEmpty == false else {
            return "no_visible_source_basename"
        }

        let candidates = snapshot.candidateSourceDocumentPaths.filter {
            URL(fileURLWithPath: $0).lastPathComponent == basename
        }
        guard candidates.count == 1, let path = candidates.first else {
            return candidates.isEmpty ? "restore_candidate_missing" : "restore_candidate_ambiguous"
        }

        let opened = await openSourceDocument(
            at: path,
            workspacePath: snapshot.workspacePath
        )
        guard opened else {
            return "restore_open_failed"
        }
        let touched = await ensureSourceDocumentVisible(
            at: path,
            workspacePath: snapshot.workspacePath
        )
        return touched ? "restored" : "restore_touch_failed"
    }

    func resolveAbsoluteFilePath(
        workspacePath: String,
        workspaceRoot: String,
        requestedFilePath: String
    ) -> String? {
        guard let requestedRelativeComponents = sanitizedRelativePathComponents(requestedFilePath),
              requestedRelativeComponents.isEmpty == false
        else {
            return nil
        }
        let key = FileResolutionKey(
            workspacePath: workspacePath,
            filePath: requestedFilePath
        )
        if let cached = resolvedFilePathCache[key] {
            return cached
        }

        let directURL = requestedRelativeComponents.reduce(
            URL(fileURLWithPath: workspaceRoot)
        ) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        let directPath = directURL.standardizedFileURL.path
        if isPath(directPath, containedIn: workspaceRoot),
           fileManager.fileExists(atPath: directPath)
        {
            resolvedFilePathCache[key] = directPath
            return directPath
        }

        guard let requestedBasename = requestedRelativeComponents.last?.lowercased() else {
            return nil
        }
        let requestedComponents = requestedRelativeComponents.map { $0.lowercased() }
        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: workspaceRoot),
            includingPropertiesForKeys: nil
        )

        var bestPath: String?
        var bestScore = 0
        var ambiguous = false

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.hasDirectoryPath == false else { continue }
            guard fileURL.lastPathComponent.lowercased() == requestedBasename else { continue }
            guard isPath(fileURL.path, containedIn: workspaceRoot) else { continue }

            let score = suffixMatchScore(
                requestedComponents: requestedComponents,
                candidateComponents: normalizedPathComponents(fileURL.path)
            )
            guard score > 0 else { continue }

            if score > bestScore {
                bestScore = score
                bestPath = fileURL.path
                ambiguous = false
            } else if score == bestScore {
                ambiguous = true
            }
        }

        guard ambiguous == false, let bestPath else {
            return nil
        }
        resolvedFilePathCache[key] = bestPath
        return bestPath
    }

    func workspaceRoot(for workspacePath: String) -> String {
        let url = URL(fileURLWithPath: workspacePath)
        if ["xcworkspace", "xcodeproj"].contains(url.pathExtension.lowercased()) {
            return url.deletingLastPathComponent().path
        }
        return workspacePath
    }

    func visibleSourceBasename(from windowTitle: String) -> String? {
        let separators = [" — ", " - "]
        for separator in separators {
            let parts = windowTitle.components(separatedBy: separator)
            if parts.count > 1, let candidate = parts.last, candidate.isEmpty == false {
                return candidate
            }
        }
        return nil
    }

    private func resolveWorkspacePath(
        tabIdentifier: String,
        sessionId: String,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider
    ) async -> String? {
        let cached = workspacePathCache[tabIdentifier]
        guard let windows = await windowsProvider(sessionId, eventLoop) else {
            return cached
        }
        guard let workspacePath = windows.first(where: { $0.tabIdentifier == tabIdentifier })?.workspacePath else {
            workspacePathCache.removeValue(forKey: tabIdentifier)
            return nil
        }
        workspacePathCache[tabIdentifier] = workspacePath
        return workspacePath
    }

    private func editorSnapshot(
        workspacePath: String,
        workspaceRoot: String
    ) async -> EditorSnapshot? {
        let windowTitle = await windowTitle(for: workspacePath) ?? ""
        let sourceDocumentPaths = await sourceDocumentPaths()
        let candidates = sourceDocumentPaths.filter { isPath($0, containedIn: workspaceRoot) }
        return EditorSnapshot(
            workspacePath: workspacePath,
            workspaceRoot: workspaceRoot,
            windowTitle: windowTitle,
            candidateSourceDocumentPaths: candidates,
            visibleSourceBasename: visibleSourceBasename(from: windowTitle)
        )
    }

    private func openSourceDocument(
        at absolutePath: String,
        workspacePath: String
    ) async -> Bool {
        let script = """
        tell application "Xcode"
            repeat with w in windows
                try
                    if (path of document of w) is \(appleScriptString(workspacePath)) then
                        set index of w to 1
                        exit repeat
                    end if
                end try
            end repeat
            open POSIX file \(appleScriptString(absolutePath))
        end tell
        return "ok"
        """
        let output = await runAppleScript(label: "open-source-document", script: script)
        return output?.terminationStatus == 0
    }

    private func ensureSourceDocumentVisible(
        at absolutePath: String,
        workspacePath: String
    ) async -> Bool {
        let script = """
        tell application "Xcode"
            repeat with w in windows
                try
                    if (path of document of w) is \(appleScriptString(workspacePath)) then
                        set index of w to 1
                        exit repeat
                    end if
                end try
            end repeat
            try
                set openedDocuments to open POSIX file \(appleScriptString(absolutePath))
                set d to item 1 of openedDocuments
                hack document d start 1 stop 1
                return "ready"
            on error
                return "missing"
            end try
        end tell
        """
        let output = await runAppleScript(label: "touch-source-document", script: script)
        guard output?.terminationStatus == 0 else { return false }
        return output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ready"
    }

    private func windowTitle(for workspacePath: String) async -> String? {
        let script = """
        tell application "Xcode"
            repeat with w in windows
                try
                    if (path of document of w) is \(appleScriptString(workspacePath)) then
                        return name of w
                    end if
                end try
            end repeat
        end tell
        return ""
        """
        let output = await runAppleScript(label: "window-title", script: script)
        guard output?.terminationStatus == 0 else { return nil }
        let text = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func sourceDocumentPaths() async -> [String] {
        let script = """
        tell application "Xcode"
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            try
                set docPaths to (path of source documents) as text
            on error
                set docPaths to ""
            end try
            set AppleScript's text item delimiters to oldDelimiters
            return docPaths
        end tell
        """
        let output = await runAppleScript(label: "source-document-paths", script: script)
        guard output?.terminationStatus == 0 else { return [] }
        return output?.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false } ?? []
    }

    private func runAppleScript(label: String, script: String) async -> ProcessOutput? {
        do {
            let output = try await processRunner.run(
                ProcessRequest(
                    label: label,
                    executablePath: "/usr/bin/osascript",
                    arguments: ["-"],
                    input: script
                )
            )
            if output.terminationStatus != 0 {
                logger.debug(
                    "AppleScript failed",
                    metadata: [
                        "label": .string(label),
                        "status": .string("\(output.terminationStatus)"),
                        "stderr": .string(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)),
                    ]
                )
            }
            return output
        } catch {
            logger.debug(
                "AppleScript execution failed",
                metadata: [
                    "label": .string(label),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func normalizedPathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents
            .filter { $0 != "/" && $0 != "." }
            .map { $0.lowercased() }
    }

    private func sanitizedRelativePathComponents(_ path: String) -> [String]? {
        guard path.isEmpty == false, path.hasPrefix("/") == false else { return nil }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components
    }

    private func isPath(_ path: String, containedIn workspaceRoot: String) -> Bool {
        let resolvedPath = resolvedPathForContainment(path)
        let resolvedRoot = resolvedPathForContainment(workspaceRoot)
        guard resolvedRoot.isEmpty == false else { return false }
        if resolvedPath == resolvedRoot {
            return true
        }
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath.hasPrefix(rootPrefix)
    }

    private func resolvedPathForContainment(_ path: String) -> String {
        let symlinkResolvedPath = (path as NSString).resolvingSymlinksInPath
        return URL(fileURLWithPath: symlinkResolvedPath).standardizedFileURL.path
    }

    private func suffixMatchScore(
        requestedComponents: [String],
        candidateComponents: [String]
    ) -> Int {
        let requested = Array(requestedComponents.reversed())
        let candidate = Array(candidateComponents.reversed())
        var score = 0
        for (lhs, rhs) in zip(requested, candidate) {
            guard lhs == rhs else { break }
            score += 1
        }
        return score
    }
}
