import Foundation

enum IdCodec {
    static func encode(sessionId: String, originalId: Any) -> String {
        if JSONSerialization.isValidJSONObject([originalId]),
           let data = try? JSONSerialization.data(withJSONObject: [originalId], options: []) {
            let encoded = data.base64EncodedString()
            return "\(sessionId)|\(encoded)"
        }
        return "\(sessionId)|\(String(describing: originalId))"
    }

    static func decode(_ prefixedId: String) -> (sessionId: String, originalId: Any)? {
        guard let separatorIndex = prefixedId.firstIndex(of: "|") else { return nil }
        let sessionId = String(prefixedId[..<separatorIndex])
        let payload = String(prefixedId[prefixedId.index(after: separatorIndex)...])
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = json as? [Any],
              array.count == 1 else {
            return nil
        }
        return (sessionId, array[0])
    }

    static func stripPrefix(sessionId: String, id: Any?) -> Any? {
        guard let idString = id as? String,
              let decoded = decode(idString),
              decoded.sessionId == sessionId else {
            return id
        }
        return decoded.originalId
    }
}
