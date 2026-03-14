import Foundation
import Logging
import TOMLDecoder

package enum ProxyFileConfigLoader {
    package static func loadInitializeParamsOverride(
        configPath: String?,
        logger: Logger
    ) -> [String: JSONValue]? {
        guard let rawPath = nonEmpty(configPath) else { return nil }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning(
                "Failed to read proxy config; using built-in initialize params",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }

        let rootTable: TOMLTable
        do {
            rootTable = try TOMLTable(source: data)
        } catch {
            logger.warning(
                "Failed to decode proxy config; using built-in initialize params",
                metadata: [
                    "path": .string(expandedPath),
                    "error": .string(String(describing: error)),
                ]
            )
            return nil
        }

        let handshakeTable: TOMLTable
        do {
            handshakeTable = try rootTable.table(forKey: "upstream_handshake")
        } catch {
            logger.warning(
                "Proxy config does not define upstream_handshake; using built-in initialize params",
                metadata: ["path": .string(expandedPath)]
            )
            return nil
        }

        var params: [String: JSONValue] = [:]

        if handshakeTable.contains(key: "protocolVersion") {
            do {
                params["protocolVersion"] = .string(try handshakeTable.string(forKey: "protocolVersion"))
            } catch {
                logger.warning(
                    "Proxy config protocolVersion is invalid; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }
        }

        var clientInfo: [String: JSONValue] = [:]
        if handshakeTable.contains(key: "clientName") {
            do {
                clientInfo["name"] = .string(try handshakeTable.string(forKey: "clientName"))
            } catch {
                logger.warning(
                    "Proxy config clientName is invalid; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }
        }
        if handshakeTable.contains(key: "clientVersion") {
            do {
                clientInfo["version"] = .string(try handshakeTable.string(forKey: "clientVersion"))
            } catch {
                logger.warning(
                    "Proxy config clientVersion is invalid; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }
        }
        if !clientInfo.isEmpty {
            params["clientInfo"] = .object(clientInfo)
        }

        if handshakeTable.contains(key: "capabilities") {
            let capabilitiesTable: TOMLTable
            do {
                capabilitiesTable = try handshakeTable.table(forKey: "capabilities")
            } catch {
                logger.warning(
                    "Proxy config capabilities is invalid; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }

            let capabilitiesObject: [String: Any]
            do {
                capabilitiesObject = try Dictionary(capabilitiesTable)
            } catch {
                logger.warning(
                    "Failed to materialize proxy config capabilities; using built-in initialize params",
                    metadata: [
                        "path": .string(expandedPath),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }

            let capabilities = capabilitiesObject.compactMapValues(JSONValue.init(any:))
            guard capabilities.count == capabilitiesObject.count else {
                logger.warning(
                    "Proxy config capabilities are not JSON-compatible; using built-in initialize params",
                    metadata: ["path": .string(expandedPath)]
                )
                return nil
            }
            params["capabilities"] = .object(capabilities)
        }

        return params.isEmpty ? nil : params
    }

    package static func mergeJSONObjects(
        _ base: [String: JSONValue],
        overriding override: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = base
        for (key, value) in override {
            if case .object(let overrideObject) = value,
               case .object(let baseObject)? = merged[key]
            {
                merged[key] = .object(
                    mergeJSONObjects(baseObject, overriding: overrideObject)
                )
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }
}
