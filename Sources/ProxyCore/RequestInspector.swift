import Foundation

package struct RequestTransform {
    package let upstreamData: Data
    package let expectsResponse: Bool
    package let isBatch: Bool
    package let idKey: String?
    package let responseIDs: [RPCID]
    package let method: String?
    package let originalID: RPCID?
    package let isCacheableToolsListRequest: Bool
}

package enum RequestInspector {
    package static func transform(
        _ data: Data,
        sessionID: String,
        mapID: (_ sessionID: String, _ originalID: RPCID) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            // We intentionally treat tools/list as stable and cache it regardless of params.
            // Some clients attach pagination-like params even when they expect the full list.
            let isCacheableToolsListRequest = (method == "tools/list")
            if let id = object["id"], let rpcID = RPCID(any: id) {
                let upstreamID = mapID(sessionID, rpcID)
                object["id"] = upstreamID
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcID.key,
                    responseIDs: [rpcID],
                    method: method,
                    originalID: rpcID,
                    isCacheableToolsListRequest: isCacheableToolsListRequest
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                responseIDs: [],
                method: method,
                originalID: nil,
                isCacheableToolsListRequest: isCacheableToolsListRequest
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var responseIDs: [RPCID] = []
            responseIDs.reserveCapacity(array.count)
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcID = RPCID(any: id) {
                        let upstreamID = mapID(sessionID, rpcID)
                        object["id"] = upstreamID
                        responseIDs.append(rpcID)
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: !responseIDs.isEmpty,
                isBatch: true,
                idKey: nil,
                responseIDs: responseIDs,
                method: nil,
                originalID: nil,
                isCacheableToolsListRequest: false
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            responseIDs: [],
            method: nil,
            originalID: nil,
            isCacheableToolsListRequest: false
        )
    }
}
