import Foundation

package struct RequestTransform {
    package let upstreamData: Data
    package let expectsResponse: Bool
    package let isBatch: Bool
    package let idKey: String?
    package let responseIds: [RPCId]
    package let method: String?
    package let originalId: RPCId?
    package let isCacheableToolsListRequest: Bool
}

package enum RequestInspector {
    package static func transform(
        _ data: Data,
        sessionId: String,
        mapId: (_ sessionId: String, _ originalId: RPCId) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            // We intentionally treat tools/list as stable and cache it regardless of params.
            // Some clients attach pagination-like params even when they expect the full list.
            let isCacheableToolsListRequest = (method == "tools/list")
            if let id = object["id"], let rpcId = RPCId(any: id) {
                let upstreamId = mapId(sessionId, rpcId)
                object["id"] = upstreamId
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcId.key,
                    responseIds: [rpcId],
                    method: method,
                    originalId: rpcId,
                    isCacheableToolsListRequest: isCacheableToolsListRequest
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                responseIds: [],
                method: method,
                originalId: nil,
                isCacheableToolsListRequest: isCacheableToolsListRequest
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var responseIds: [RPCId] = []
            responseIds.reserveCapacity(array.count)
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcId = RPCId(any: id) {
                        let upstreamId = mapId(sessionId, rpcId)
                        object["id"] = upstreamId
                        responseIds.append(rpcId)
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: !responseIds.isEmpty,
                isBatch: true,
                idKey: nil,
                responseIds: responseIds,
                method: nil,
                originalId: nil,
                isCacheableToolsListRequest: false
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            responseIds: [],
            method: nil,
            originalId: nil,
            isCacheableToolsListRequest: false
        )
    }
}
