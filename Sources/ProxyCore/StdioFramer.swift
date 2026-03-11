import Foundation

package struct StdioFramerRecovery: Sendable {
    package enum Kind: String, Codable, Sendable {
        case resync
        case fatalClear
    }

    package let kind: Kind
    package let droppedPrefixBytes: Int
    package let candidateOffset: Int?
    package let previewBeforeDrop: String
    package let previewRecoveredMessage: String?

    package init(
        kind: Kind,
        droppedPrefixBytes: Int,
        candidateOffset: Int?,
        previewBeforeDrop: String,
        previewRecoveredMessage: String?
    ) {
        self.kind = kind
        self.droppedPrefixBytes = droppedPrefixBytes
        self.candidateOffset = candidateOffset
        self.previewBeforeDrop = previewBeforeDrop
        self.previewRecoveredMessage = previewRecoveredMessage
    }
}

package struct StdioFramerAppendResult: Sendable {
    package let messages: [Data]
    package let recoveries: [StdioFramerRecovery]
    package let bufferedByteCount: Int

    package init(messages: [Data], recoveries: [StdioFramerRecovery], bufferedByteCount: Int) {
        self.messages = messages
        self.recoveries = recoveries
        self.bufferedByteCount = bufferedByteCount
    }
}

package final class StdioFramer {
    private enum JSONPrefixParseResult {
        case complete(Data.Index)
        case incomplete
        case invalid
    }

    private let resyncScanThreshold = 16 * 1024
    private let bufferHardLimit = 4 * 1024 * 1024
    private let previewLimit = 200

    private var buffer = Data()

    package init() {}

    package func append(_ data: Data) -> StdioFramerAppendResult {
        guard !data.isEmpty else {
            return StdioFramerAppendResult(messages: [], recoveries: [], bufferedByteCount: buffer.count)
        }

        buffer.append(data)
        var messages: [Data] = []
        var recoveries: [StdioFramerRecovery] = []

        while true {
            if let message = nextContentLengthMessage() {
                messages.append(message)
                continue
            }
            if let message = nextJSONValueMessage() {
                messages.append(message)
                continue
            }
            if trimLeadingWhitespace() {
                continue
            }
            if dropLeadingNonJSONLine() {
                continue
            }
            if let recovery = recoverCorruptJSONPrefixIfNeeded() {
                recoveries.append(recovery)
                continue
            }
            break
        }

        return StdioFramerAppendResult(
            messages: messages,
            recoveries: recoveries,
            bufferedByteCount: buffer.count
        )
    }

    private func nextContentLengthMessage() -> Data? {
        let headerPrefix = "Content-Length"
        guard buffer.count >= headerPrefix.count else { return nil }
        guard let prefixString = String(data: buffer.prefix(headerPrefix.count), encoding: .utf8),
              prefixString.caseInsensitiveCompare(headerPrefix) == .orderedSame else {
            return nil
        }

        let delimiterCRLF = Data("\r\n\r\n".utf8)
        let delimiterLF = Data("\n\n".utf8)
        let headerEndRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF)
        guard let headerRange = headerEndRange else { return nil }
        let headerEndIndex = headerRange.upperBound
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8),
              let length = parseContentLength(from: headerText) else { return nil }
        guard buffer.count >= headerEndIndex + length else { return nil }

        let bodyEndIndex = headerEndIndex + length
        let bodyRange = headerEndIndex..<bodyEndIndex

        if let jsonStart = firstNonWhitespaceIndex(in: bodyRange),
           buffer[jsonStart] == 0x7B || buffer[jsonStart] == 0x5B,
           let jsonEndIndex = jsonValueEndIndex(from: jsonStart),
           jsonEndIndex <= bodyEndIndex,
           buffer[jsonEndIndex..<bodyEndIndex].allSatisfy({ isWhitespace($0) }) {
            let message = buffer.subdata(in: bodyRange)
            buffer.removeSubrange(0..<bodyEndIndex)
            return message
        }

        buffer.removeSubrange(0..<headerEndIndex)
        return nil
    }

    private func nextJSONValueMessage() -> Data? {
        guard let startIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }
        let first = buffer[startIndex]
        guard first == 0x7B || first == 0x5B else { return nil }
        guard let messageEnd = jsonValueEndIndex(from: startIndex) else { return nil }

        let message = buffer.subdata(in: startIndex..<messageEnd)
        guard isValidJSONObjectOrArray(message) else { return nil }
        buffer.removeSubrange(0..<messageEnd)
        return message
    }

    private func trimLeadingWhitespace() -> Bool {
        guard !buffer.isEmpty else { return false }
        var index = buffer.startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        if index == buffer.startIndex {
            return false
        }
        if index == buffer.endIndex {
            buffer.removeAll(keepingCapacity: true)
            return true
        }
        buffer.removeSubrange(0..<index)
        return true
    }

    private func dropLeadingNonJSONLine() -> Bool {
        guard !buffer.isEmpty else { return false }

        if isPotentialContentLengthHeaderPrefix() {
            let delimiterCRLF = Data("\r\n\r\n".utf8)
            let delimiterLF = Data("\n\n".utf8)

            if let headerRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF) {
                let headerEndIndex = headerRange.upperBound
                let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)

                if let headerText = String(data: headerData, encoding: .utf8),
                   let length = parseContentLength(from: headerText) {
                    if let bodyStart = firstNonWhitespaceIndex(from: headerEndIndex) {
                        if buffer[bodyStart] != 0x7B && buffer[bodyStart] != 0x5B {
                            buffer.removeSubrange(0..<headerEndIndex)
                            return true
                        }

                        if let jsonEndIndex = jsonValueEndIndex(from: bodyStart) {
                            let observedLength = buffer.distance(from: headerEndIndex, to: jsonEndIndex)
                            if observedLength != length {
                                buffer.removeSubrange(0..<headerEndIndex)
                                return true
                            }
                        }
                    }

                    return false
                }
            }

            guard let firstNewlineIndex = buffer.firstIndex(of: 0x0A) else {
                return false
            }

            let afterNewline = buffer.index(after: firstNewlineIndex)
            if afterNewline == buffer.endIndex {
                return false
            }

            let hasJSONStartAfterNewline = buffer[afterNewline...].contains { $0 == 0x7B || $0 == 0x5B }
            if !hasJSONStartAfterNewline, buffer.count < 8 * 1024 {
                return false
            }
        }

        if let first = firstNonWhitespaceByte(), first == 0x7B || first == 0x5B {
            return false
        }

        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return false }
        let dropEnd = buffer.index(after: newlineIndex)
        buffer.removeSubrange(0..<dropEnd)
        return true
    }

    private func recoverCorruptJSONPrefixIfNeeded() -> StdioFramerRecovery? {
        guard let firstIndex = firstNonWhitespaceIndex(from: buffer.startIndex) else { return nil }
        let rootByte = buffer[firstIndex]
        guard rootByte == 0x7B || rootByte == 0x5B else { return nil }

        switch jsonPrefixParseResult(from: firstIndex) {
        case .complete, .incomplete:
            return nil
        case .invalid:
            break
        }

        // Invalid JSON at the buffer head is already a proven corruption signal, so recover as soon
        // as we can find a later top-level root instead of waiting for the large-buffer threshold.
        let allowsLooseLineBoundaries = buffer.count > resyncScanThreshold
        let minimumCandidateIndex = allowsLooseLineBoundaries ? nil : jsonValueEndIndex(from: firstIndex)
        if !allowsLooseLineBoundaries, minimumCandidateIndex == nil {
            return nil
        }

        let candidates = recoveryCandidateOffsets(
            startingAfter: buffer.index(after: firstIndex),
            allowsObjectRoots: true,
            allowsArrayRoots: true,
            minimumCandidateIndex: minimumCandidateIndex
        )
        for candidate in candidates {
            guard let messageEnd = jsonValueEndIndex(from: candidate) else { continue }
            let recovered = buffer.subdata(in: candidate..<messageEnd)
            guard isValidRecoveryRoot(recovered) else { continue }

            let droppedPrefix = buffer.subdata(in: 0..<candidate)
            buffer.removeSubrange(0..<candidate)
            return StdioFramerRecovery(
                kind: .resync,
                droppedPrefixBytes: candidate,
                candidateOffset: candidate,
                previewBeforeDrop: preview(of: droppedPrefix, preferTail: true),
                previewRecoveredMessage: preview(of: recovered, preferTail: false)
            )
        }

        if buffer.count > bufferHardLimit {
            let dropped = buffer
            let droppedCount = buffer.count
            buffer.removeAll(keepingCapacity: true)
            return StdioFramerRecovery(
                kind: .fatalClear,
                droppedPrefixBytes: droppedCount,
                candidateOffset: nil,
                previewBeforeDrop: preview(of: dropped, preferTail: true),
                previewRecoveredMessage: nil
            )
        }

        return nil
    }

    private func recoveryCandidateOffsets(
        startingAfter lowerBound: Data.Index,
        allowsObjectRoots: Bool,
        allowsArrayRoots: Bool,
        minimumCandidateIndex: Data.Index?
    ) -> [Data.Index] {
        guard lowerBound < buffer.endIndex else { return [] }
        var offsets: [Data.Index] = []
        offsets.reserveCapacity(8)
        var index = lowerBound
        while index < buffer.endIndex {
            let byte = buffer[index]
            let isAllowedObjectRoot = byte == 0x7B && allowsObjectRoots
            let isAllowedArrayRoot = byte == 0x5B && allowsArrayRoots
            let clearsMinimumBoundary = minimumCandidateIndex.map { index >= $0 } ?? true
            if (isAllowedObjectRoot || isAllowedArrayRoot),
               clearsMinimumBoundary,
               isRecoveryBoundary(at: index),
               isPlausibleRecoveryRoot(at: index) {
                offsets.append(index)
            }
            index = buffer.index(after: index)
        }
        return offsets
    }

    private func isRecoveryBoundary(at index: Data.Index) -> Bool {
        guard index > buffer.startIndex else { return true }
        let previous = buffer[buffer.index(before: index)]
        if previous == 0x7D || previous == 0x5D {
            return true
        }
        return previous == 0x0A
    }

    private func isPlausibleRecoveryRoot(at index: Data.Index) -> Bool {
        guard index < buffer.endIndex else { return false }
        let byte = buffer[index]
        guard byte == 0x7B || byte == 0x5B else { return false }

        let contentStart = buffer.index(after: index)
        guard let nextIndex = firstNonWhitespaceIndex(from: contentStart) else { return false }

        if byte == 0x7B {
            return buffer[nextIndex] == 0x22
        }

        return buffer[nextIndex] == 0x7B
    }

    private func isValidRecoveryRoot(_ data: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }

        if let object = any as? [String: Any] {
            guard object["jsonrpc"] as? String == "2.0" else { return false }
            return object["id"] != nil || object["method"] is String
        }

        if let array = any as? [Any] {
            guard let first = array.first as? [String: Any] else { return false }
            return first["jsonrpc"] as? String == "2.0"
        }

        return false
    }

    private func isValidJSONObjectOrArray(_ data: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return any is [String: Any] || any is [Any]
    }

    private func firstNonWhitespaceByte() -> UInt8? {
        guard let index = firstNonWhitespaceIndex(from: buffer.startIndex) else {
            return nil
        }
        return buffer[index]
    }

    private func firstNonWhitespaceIndex(from startIndex: Data.Index) -> Data.Index? {
        var index = startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else { return nil }
        return index
    }

    private func firstNonWhitespaceIndex(in range: Range<Data.Index>) -> Data.Index? {
        var index = range.lowerBound
        while index < range.upperBound, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        guard index < range.upperBound else { return nil }
        return index
    }

    private func jsonValueEndIndex(from startIndex: Data.Index) -> Data.Index? {
        var index = startIndex
        guard index < buffer.endIndex else { return nil }
        let first = buffer[index]
        guard first == 0x7B || first == 0x5B else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var endIndex: Data.Index?

        while index < buffer.endIndex {
            let byte = buffer[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        endIndex = index
                        break
                    }
                }
            }
            index = buffer.index(after: index)
        }

        guard let endIndex, depth == 0, !inString else { return nil }
        return buffer.index(after: endIndex)
    }

    private func jsonPrefixParseResult(from startIndex: Data.Index) -> JSONPrefixParseResult {
        parseJSONValuePrefix(from: startIndex)
    }

    private func parseJSONValuePrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        let index = skipWhitespace(from: startIndex)
        guard index < buffer.endIndex else { return .incomplete }

        switch buffer[index] {
        case 0x7B:
            return parseJSONObjectPrefix(from: index)
        case 0x5B:
            return parseJSONArrayPrefix(from: index)
        case 0x22:
            return parseJSONStringPrefix(from: index)
        case 0x74:
            return parseJSONLiteralPrefix("true", from: index)
        case 0x66:
            return parseJSONLiteralPrefix("false", from: index)
        case 0x6E:
            return parseJSONLiteralPrefix("null", from: index)
        case 0x2D, 0x30 ... 0x39:
            return parseJSONNumberPrefix(from: index)
        default:
            return .invalid
        }
    }

    private func parseJSONObjectPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = skipWhitespace(from: buffer.index(after: startIndex))
        guard index < buffer.endIndex else { return .incomplete }
        if buffer[index] == 0x7D {
            return .complete(buffer.index(after: index))
        }

        while true {
            switch parseJSONStringPrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            guard buffer[index] == 0x3A else { return .invalid }
            index = skipWhitespace(from: buffer.index(after: index))

            switch parseJSONValuePrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            let byte = buffer[index]
            if byte == 0x2C {
                index = skipWhitespace(from: buffer.index(after: index))
                guard index < buffer.endIndex else { return .incomplete }
                continue
            }
            if byte == 0x7D {
                return .complete(buffer.index(after: index))
            }
            return .invalid
        }
    }

    private func parseJSONArrayPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = skipWhitespace(from: buffer.index(after: startIndex))
        guard index < buffer.endIndex else { return .incomplete }
        if buffer[index] == 0x5D {
            return .complete(buffer.index(after: index))
        }

        while true {
            switch parseJSONValuePrefix(from: index) {
            case .complete(let nextIndex):
                index = skipWhitespace(from: nextIndex)
            case .incomplete:
                return .incomplete
            case .invalid:
                return .invalid
            }

            guard index < buffer.endIndex else { return .incomplete }
            let byte = buffer[index]
            if byte == 0x2C {
                index = skipWhitespace(from: buffer.index(after: index))
                guard index < buffer.endIndex else { return .incomplete }
                continue
            }
            if byte == 0x5D {
                return .complete(buffer.index(after: index))
            }
            return .invalid
        }
    }

    private func parseJSONStringPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        guard startIndex < buffer.endIndex, buffer[startIndex] == 0x22 else { return .invalid }

        var index = buffer.index(after: startIndex)
        var isEscaped = false
        var pendingUnicodeDigits = 0

        while index < buffer.endIndex {
            let byte = buffer[index]
            if pendingUnicodeDigits > 0 {
                guard isHexDigit(byte) else { return .invalid }
                pendingUnicodeDigits -= 1
            } else if isEscaped {
                switch byte {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    isEscaped = false
                case 0x75:
                    isEscaped = false
                    pendingUnicodeDigits = 4
                default:
                    return .invalid
                }
            } else if byte == 0x5C {
                isEscaped = true
            } else if byte == 0x22 {
                return .complete(buffer.index(after: index))
            } else if byte < 0x20 {
                return .invalid
            }

            index = buffer.index(after: index)
        }

        return .incomplete
    }

    private func parseJSONLiteralPrefix(_ literal: StaticString, from startIndex: Data.Index) -> JSONPrefixParseResult {
        let bytes = Array(String(describing: literal).utf8)
        var index = startIndex

        for expected in bytes {
            guard index < buffer.endIndex else { return .incomplete }
            guard buffer[index] == expected else { return .invalid }
            index = buffer.index(after: index)
        }

        if index < buffer.endIndex, !isJSONValueTerminator(buffer[index]) {
            return .invalid
        }
        return .complete(index)
    }

    private func parseJSONNumberPrefix(from startIndex: Data.Index) -> JSONPrefixParseResult {
        var index = startIndex
        let start = index

        if buffer[index] == 0x2D {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
        }

        guard index < buffer.endIndex else { return .incomplete }
        switch buffer[index] {
        case 0x30:
            index = buffer.index(after: index)
            if index < buffer.endIndex, isDigit(buffer[index]) {
                return .invalid
            }
        case 0x31 ... 0x39:
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        default:
            return index == start ? .invalid : .incomplete
        }

        if index < buffer.endIndex, buffer[index] == 0x2E {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
            guard isDigit(buffer[index]) else { return .invalid }
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        }

        if index < buffer.endIndex, buffer[index] == 0x45 || buffer[index] == 0x65 {
            index = buffer.index(after: index)
            guard index < buffer.endIndex else { return .incomplete }
            if buffer[index] == 0x2B || buffer[index] == 0x2D {
                index = buffer.index(after: index)
                guard index < buffer.endIndex else { return .incomplete }
            }
            guard isDigit(buffer[index]) else { return .invalid }
            repeat {
                index = buffer.index(after: index)
            } while index < buffer.endIndex && isDigit(buffer[index])
        }

        if index < buffer.endIndex, !isJSONValueTerminator(buffer[index]) {
            return .invalid
        }
        return .complete(index)
    }

    private func skipWhitespace(from startIndex: Data.Index) -> Data.Index {
        var index = startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        return index
    }

    private func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Length") == .orderedSame {
                guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), length >= 0 else {
                    return nil
                }
                return length
            }
        }
        return nil
    }

    private func isPotentialContentLengthHeaderPrefix() -> Bool {
        let headerPrefix = "Content-Length"
        let count = min(buffer.count, headerPrefix.utf8.count)
        guard count > 0 else { return false }
        guard let prefix = String(data: buffer.prefix(count), encoding: .utf8) else { return false }
        return headerPrefix.lowercased().hasPrefix(prefix.lowercased())
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    private func isJSONValueTerminator(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x2C || byte == 0x5D || byte == 0x7D
    }

    private func preview(of data: Data, preferTail: Bool) -> String {
        guard !data.isEmpty else { return "" }
        let slice: Data
        if data.count <= previewLimit {
            slice = data
        } else if preferTail {
            slice = data.suffix(previewLimit)
        } else {
            slice = data.prefix(previewLimit)
        }

        let text = String(decoding: slice, as: UTF8.self)
        return data.count > previewLimit && preferTail ? "..." + text : text
    }
}
