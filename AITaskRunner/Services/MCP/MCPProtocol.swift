import Foundation

nonisolated enum MCP {
    static let protocolVersion = "2025-06-18"
    static let clientInfo: JSONValue = ["name": "AITaskRunner", "version": "1.0"]
}

nonisolated struct MCPTool: Identifiable, Hashable, Sendable, Codable {
    var name: String
    var description: String?
    var inputSchema: JSONValue

    var id: String { name }

    init?(json: JSONValue) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        self.description = json["description"]?.string
        var schema = json["inputSchema"] ?? ["type": "object"]
        if schema["type"] == nil, var object = schema.object {
            object["type"] = "object"
            schema = .object(object)
        }
        self.inputSchema = schema
    }
}

/// One image item from a tool result, exactly as the server sent it (MCP `image` content or an
/// embedded resource with an `image/*` blob).
nonisolated struct MCPImage: Sendable, Hashable {
    var mimeType: String
    var base64: String

    /// Size of the decoded image, without decoding it.
    var decodedByteCount: Int { base64.utf8.count / 4 * 3 }
}

nonisolated struct MCPToolResult: Sendable {
    var text: String
    var isError: Bool
    var images: [MCPImage] = []

    /// The text plus a note about any images, for models that cannot receive image input.
    var textDescribingImages: String {
        guard !images.isEmpty else { return text }
        return text + "\n[\(images.count) image(s) returned; this model cannot see images]"
    }
}

nonisolated struct MCPServerInfo: Sendable, Hashable {
    var name: String
    var version: String
    var protocolVersion: String
    var instructions: String?

    init(initializeResult json: JSONValue) {
        name = json["serverInfo"]?["name"]?.string ?? "Unknown"
        version = json["serverInfo"]?["version"]?.string ?? ""
        protocolVersion = json["protocolVersion"]?.string ?? ""
        instructions = json["instructions"]?.string
    }
}

nonisolated enum MCPError: LocalizedError, Sendable {
    case notConnected
    case transportClosed(String)
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case launchFailed(String)
    case http(Int, String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the MCP server."
        case .transportClosed(let reason): return "MCP connection closed: \(reason)"
        case .invalidResponse(let detail): return "Invalid MCP response: \(detail)"
        case .rpc(let code, let message): return "MCP error \(code): \(message)"
        case .launchFailed(let detail): return "Could not launch MCP server: \(detail)"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(status)" + (trimmed.isEmpty ? "" : ": \(trimmed.prefix(300))")
        case .timeout(let method): return "Timed out waiting for MCP response to \(method)."
        }
    }
}

/// Bidirectional JSON-RPC pipe. Implementations deliver every inbound message through `onMessage`.
nonisolated protocol MCPTransport: AnyObject, Sendable {
    func start(
        onMessage: @escaping @Sendable (JSONValue) -> Void,
        onClose: @escaping @Sendable (String) -> Void
    ) async throws
    func send(_ message: JSONValue) async throws
    func close() async
}

nonisolated enum JSONRPC {
    static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        return .object(message)
    }

    static func notification(method: String, params: JSONValue?) -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        return .object(message)
    }

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    /// True for a response (success or error) to the given request id.
    static func isResponse(_ message: JSONValue, to id: JSONValue?) -> Bool {
        guard let id, message["method"] == nil, let messageID = message["id"] else { return false }
        return messageID == id
    }
}
