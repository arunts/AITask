import Foundation

/// Native tool packs that ship with AITaskRunner. They sit next to MCP servers in every list and use the
/// same `slug__tool` naming, but run in-process and need nothing installed.
nonisolated enum BuiltinToolPack: String, CaseIterable, Identifiable, Sendable {
    case shell

    /// Stable identity so task attachments survive restarts.
    var id: UUID {
        switch self {
        case .shell: return UUID(uuidString: "0DD70B5F-0000-4000-8000-000000000002")!
        }
    }

    init?(id: UUID) {
        guard let match = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    /// Looks a pack up by the name used in task files. Accepts the old name `bash` for `shell`.
    init?(slug: String) {
        switch slug.lowercased() {
        case "bash": self = .shell
        default:
            guard let match = BuiltinToolPack(rawValue: slug.lowercased()) else { return nil }
            self = match
        }
    }

    var name: String {
        switch self {
        case .shell: return "Shell"
        }
    }

    var description: String {
        switch self {
        case .shell:
            return "Run a shell command and return its output and exit code. Commands run in your login shell with your PATH, so the model can read, write and search files with the usual tools."
        }
    }

    var definitions: [BuiltinTool] {
        switch self {
        case .shell: return ShellToolPack.definitions
        }
    }

    /// The pack's tools in the shape MCP servers use, so callers treat both alike.
    var tools: [MCPTool] { definitions.map(\.mcpTool) }

    /// The pseudo-server other code sees (slug `shell__`).
    var config: MCPServerConfig {
        MCPServerConfig(id: id, name: name, transport: .builtin)
    }

    /// Tools that must be approved by the user before they execute.
    func requiresApproval(_ toolName: String) -> Bool {
        self == .shell
    }
}

/// One native tool.
nonisolated struct BuiltinTool: Hashable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    var mcpTool: MCPTool {
        MCPTool(name: name, description: description, inputSchema: inputSchema)
    }
}

/// Persisted preferences for the built-in packs.
nonisolated struct BuiltinToolSettings: Codable, Hashable, Sendable {
    var shellEnabled = true
    /// Folder commands start in (tilde allowed). They are not confined to it.
    var workingDirectory = NSHomeDirectory()
    var shellRequiresApproval = true
    var shellTimeoutSeconds = 60

    init() {}

    private enum CodingKeys: String, CodingKey {
        case shellEnabled, workingDirectory, shellRequiresApproval, shellTimeoutSeconds
        // Names used before the pack was renamed from Bash.
        case bashEnabled, allowedFolders, bashRequiresApproval, bashTimeoutSeconds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shellEnabled = try c.decodeIfPresent(Bool.self, forKey: .shellEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .bashEnabled) ?? true
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? c.decodeIfPresent([String].self, forKey: .allowedFolders)?.first ?? NSHomeDirectory()
        shellRequiresApproval = try c.decodeIfPresent(Bool.self, forKey: .shellRequiresApproval)
            ?? c.decodeIfPresent(Bool.self, forKey: .bashRequiresApproval) ?? true
        shellTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .shellTimeoutSeconds)
            ?? c.decodeIfPresent(Int.self, forKey: .bashTimeoutSeconds) ?? 60
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shellEnabled, forKey: .shellEnabled)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(shellRequiresApproval, forKey: .shellRequiresApproval)
        try c.encode(shellTimeoutSeconds, forKey: .shellTimeoutSeconds)
    }

    func isEnabled(_ pack: BuiltinToolPack) -> Bool {
        switch pack {
        case .shell: return shellEnabled
        }
    }

    /// The working directory with the tilde expanded; the home folder when it is blank.
    var resolvedWorkingDirectory: String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? NSHomeDirectory() : (trimmed as NSString).expandingTildeInPath
    }
}

nonisolated extension MCPTool {
    init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
