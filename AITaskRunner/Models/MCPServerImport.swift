import Foundation

/// Turns the JSON formats used by Claude Desktop, Cursor, VS Code and Claude Code into server configs.
///
/// Accepted shapes:
/// - `{"mcpServers": {"name": {...}, ...}}` or `{"servers": {...}}`
/// - `{"name": {...}, "other": {...}}` (a bare map of definitions)
/// - `{"command": "npx", "args": [...]}` (a single definition; `name` optional)
///
/// A definition is stdio when it has `command` (+ optional `args`, `env`) and HTTP when it has `url`
/// (+ optional `headers`). `type` is honoured when present ("stdio", "http", "streamable-http", "sse").
nonisolated enum MCPServerImport {
    enum ImportError: LocalizedError {
        case invalidJSON(String)
        case notAnObject
        case noServers
        case invalidDefinition(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail): return "Not valid JSON: \(detail)"
            case .notAnObject: return "The top level must be a JSON object."
            case .noServers: return "No server definitions found. Expected an \"mcpServers\" object, a map of servers, or a single definition with \"command\" or \"url\"."
            case .invalidDefinition(let name, let reason): return "“\(name)”: \(reason)"
            }
        }
    }

    static func parse(_ text: String) throws -> [MCPServerConfig] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.noServers }
        let root: JSONValue
        do {
            root = try JSONValue.parse(trimmed)
        } catch {
            throw ImportError.invalidJSON(error.localizedDescription)
        }
        guard let object = root.object else { throw ImportError.notAnObject }

        if let map = (object["mcpServers"] ?? object["servers"])?.object {
            return try definitions(from: map)
        }
        if isDefinition(root) {
            let name = object["name"]?.string ?? "Imported Server"
            return [try config(name: name, definition: root)]
        }
        let candidates = object.filter { isDefinition($0.value) }
        guard !candidates.isEmpty else { throw ImportError.noServers }
        return try definitions(from: candidates)
    }

    private static func definitions(from map: [String: JSONValue]) throws -> [MCPServerConfig] {
        let names = map.keys.sorted()
        guard !names.isEmpty else { throw ImportError.noServers }
        return try names.map { name in
            try config(name: map[name]?["name"]?.string ?? name, definition: map[name]!)
        }
    }

    private static func isDefinition(_ value: JSONValue) -> Bool {
        guard let object = value.object else { return false }
        return object["command"]?.string != nil || object["url"]?.string != nil
    }

    private static func config(name: String, definition: JSONValue) throws -> MCPServerConfig {
        guard let object = definition.object else {
            throw ImportError.invalidDefinition(name: name, reason: "expected an object")
        }
        let type = object["type"]?.string?.lowercased()
        let command = object["command"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let url = object["url"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""

        let wantsHTTP: Bool
        switch type {
        case "http", "streamable-http", "streamablehttp", "streamable_http", "sse":
            wantsHTTP = true
        case "stdio":
            wantsHTTP = false
        default:
            wantsHTTP = command.isEmpty && !url.isEmpty
        }

        if wantsHTTP {
            guard !url.isEmpty else {
                throw ImportError.invalidDefinition(name: name, reason: "HTTP servers need a \"url\".")
            }
            return MCPServerConfig(
                name: name,
                transport: .http,
                url: url,
                headers: lines(from: object["headers"], separator: ": ")
            )
        }

        guard !command.isEmpty else {
            throw ImportError.invalidDefinition(name: name, reason: "stdio servers need a \"command\".")
        }
        var args: [String] = []
        if let array = object["args"]?.array {
            args = array.map { $0.string ?? $0.textValue }
        } else if let string = object["args"]?.string {
            args = MCPServerConfig.shellSplit(string)
        }
        return MCPServerConfig(
            name: name,
            transport: .stdio,
            command: command,
            arguments: args.map(shellQuoteIfNeeded).joined(separator: " "),
            environment: lines(from: object["env"], separator: "=")
        )
    }

    private static func lines(from value: JSONValue?, separator: String) -> String {
        guard let object = value?.object else { return "" }
        return object.keys.sorted().map { key in
            "\(key)\(separator)\(object[key]?.string ?? object[key]?.textValue ?? "")"
        }.joined(separator: "\n")
    }

    /// Quotes an argument so `MCPServerConfig.shellSplit` reproduces it exactly.
    static func shellQuoteIfNeeded(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@+,~%".contains($0) }
        guard !safe || argument.isEmpty else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
