import Foundation

/// User-entered configuration for one MCP server.
nonisolated struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    enum Transport: String, Codable, CaseIterable, Sendable, Identifiable {
        case stdio
        case http
        /// Native pack that ships with the app; never user-created.
        case builtin

        var id: String { rawValue }

        /// Transports a user can pick for their own servers.
        static let userSelectable: [Transport] = [.stdio, .http]

        var label: String {
            switch self {
            case .stdio: return "Command (stdio)"
            case .http: return "HTTP (streamable)"
            case .builtin: return "Built-in"
            }
        }
    }

    var id: UUID
    var name: String
    var transport: Transport
    /// stdio: executable (resolved through the login shell's PATH).
    var command: String
    /// stdio: shell-style argument string.
    var arguments: String
    /// stdio: `KEY=VALUE` per line.
    var environment: String
    /// http: endpoint URL.
    var url: String
    /// http: `Header: Value` per line.
    var headers: String

    init(
        id: UUID = UUID(),
        name: String = "New Server",
        transport: Transport = .stdio,
        command: String = "",
        arguments: String = "",
        environment: String = "",
        url: String = "",
        headers: String = ""
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.url = url
        self.headers = headers
    }

    /// True once the user has filled in enough to attempt a connection.
    var isConfigured: Bool {
        switch transport {
        case .stdio: return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .http: return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .builtin: return true
        }
    }

    /// Prefix used in tool identifiers: `slug__toolName`.
    var slug: String { Self.slugify(name) }

    static func slugify(_ name: String) -> String {
        var output = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                output.unicodeScalars.append(scalar)
            } else if !output.hasSuffix("_") {
                output.append("_")
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return trimmed.isEmpty ? "server" : trimmed
    }

    var parsedArguments: [String] {
        Self.shellSplit(arguments).map { ($0 as NSString).expandingTildeInPath }
    }

    var parsedEnvironment: [String: String] {
        Self.keyValueLines(environment, separator: "=")
    }

    var parsedHeaders: [String: String] {
        Self.keyValueLines(headers, separator: ":")
    }

    /// Fields that require a reconnect when they change.
    var connectionSignature: String {
        [transport.rawValue, command, arguments, environment, url, headers].joined(separator: "\u{1F}")
    }

    var summary: String {
        switch transport {
        case .stdio:
            let line = ([command] + Self.shellSplit(arguments)).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? "No command" : line
        case .http:
            return url.isEmpty ? "No URL" : url
        case .builtin:
            return "Built into AITaskRunner"
        }
    }

    // MARK: Parsing helpers

    static func keyValueLines(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Minimal POSIX-style tokenizer: whitespace separation, single/double quotes, backslash escapes.
    static func shellSplit(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaping = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }
            if character == "\\", !inSingle {
                escaping = true
                continue
            }
            if character == "'", !inDouble {
                inSingle.toggle()
                hasToken = true
                continue
            }
            if character == "\"", !inSingle {
                inDouble.toggle()
                hasToken = true
                continue
            }
            if character.isWhitespace, !inSingle, !inDouble {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
