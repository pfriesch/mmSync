import Foundation

/// One MCP tool: schema for the host, handler for the call.
public struct Tool {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let annotations: [String: Any]
    public let handler: ([String: Any]) throws -> Any
}

/// Minimal MCP server: JSON-RPC 2.0, one message per line on stdin/stdout, tools only.
// devmode: hand-rolled, tools-only; switch to modelcontextprotocol/swift-sdk if we need resources, prompts or HTTP
public final class MCPServer {
    static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    let name: String
    let version: String
    let tools: [Tool]
    let icons: [[String: Any]]

    /// `icons` follow the MCP `Icon` shape: `{src, mimeType, sizes}`. Older clients ignore them.
    public init(name: String, version: String, tools: [Tool], icons: [[String: Any]] = []) {
        self.name = name
        self.version = version
        self.tools = tools
        self.icons = icons
    }

    public func run() {
        while let line = readLine() {
            guard !line.isEmpty, let response = handle(line) else { continue }
            print(response)
            fflush(stdout)
        }
    }

    /// Handles one JSON-RPC message. Returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let method = message["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil } // notification, e.g. notifications/initialized
        let params = message["params"] as? [String: Any] ?? [:]

        let result: Any
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            result = [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions.last!,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version, "icons": icons],
            ]
        case "ping":
            result = [String: Any]()
        case "tools/list":
            result = ["tools": tools.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema, "annotations": $0.annotations]
            }]
        case "tools/call":
            guard let tool = tools.first(where: { $0.name == params["name"] as? String }) else {
                return error(id, -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            result = call(tool, arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Tool failures are results with `isError`, so the model sees the message.
    private func call(_ tool: Tool, arguments: [String: Any]) -> [String: Any] {
        do {
            let value = try tool.handler(arguments)
            let text: String
            if let string = value as? String {
                text = string
            } else {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                text = String(decoding: data, as: UTF8.self)
            }
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
