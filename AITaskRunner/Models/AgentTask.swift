import Foundation

/// Which tools of one MCP server a task may call.
nonisolated struct ToolAttachment: Codable, Hashable, Sendable, Identifiable {
    var serverID: UUID
    /// `nil` means every tool the server offers (including ones added later); otherwise exactly these names.
    var toolNames: [String]?

    var id: UUID { serverID }

    init(serverID: UUID, toolNames: [String]? = nil) {
        self.serverID = serverID
        self.toolNames = toolNames
    }

    var includesAllTools: Bool { toolNames == nil }

    func includes(_ toolName: String) -> Bool {
        toolNames?.contains(toolName) ?? true
    }
}

/// Repeats a task unattended while AITaskRunner is open. Only non-interactive tasks can have one.
/// Nothing from a run is kept except when it ended and whether it succeeded.
nonisolated struct TaskSchedule: Codable, Hashable, Sendable {
    nonisolated enum Outcome: Codable, Hashable, Sendable {
        case succeeded
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .succeeded: return "Succeeded"
            case .failed(let reason): return "Failed: \(reason)"
            case .stopped: return "Stopped"
            }
        }
    }

    static let intervalRange = 1...168

    /// Hours between runs, counted from the end of the previous run.
    var intervalHours: Int = 6
    /// When the schedule was set or changed. The first run is one interval after this.
    var startedAt: Date = .now
    var lastRunAt: Date?
    var lastOutcome: Outcome?

    init(intervalHours: Int = 6, startedAt: Date = .now, lastRunAt: Date? = nil, lastOutcome: Outcome? = nil) {
        self.intervalHours = intervalHours
        self.startedAt = startedAt
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 6
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .now
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastOutcome = try c.decodeIfPresent(Outcome.self, forKey: .lastOutcome)
    }

    var interval: TimeInterval { TimeInterval(intervalHours) * 3600 }

    /// When the next run is due: one interval after the last run, or after the schedule was set.
    var nextRunAt: Date { (lastRunAt ?? startedAt).addingTimeInterval(interval) }

    func isDue(at date: Date = .now) -> Bool { nextRunAt <= date }
}

/// A named value the prompts can reference as `{{key}}`. The user sets the value before each run.
nonisolated struct TaskVariable: Codable, Hashable, Sendable, Identifiable {
    /// What kind of value the user is expected to enter; decides which controls the run sheet shows.
    nonisolated enum Kind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case text
        case file
        case folder
        /// A list of values, all of which go into the prompt; entries can be added when running.
        case list

        var id: String { rawValue }

        var label: String {
            switch self {
            case .text: return "Text"
            case .file: return "File"
            case .folder: return "Folder"
            case .list: return "List"
            }
        }

        var symbol: String {
            switch self {
            case .text: return "textformat"
            case .file: return "doc"
            case .folder: return "folder"
            case .list: return "list.bullet"
            }
        }

        var isPath: Bool { self == .file || self == .folder }

        /// Unknown kinds (from a newer build) fall back to text rather than failing the whole file.
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .text
        }
    }

    /// Most entries a list variable may hold.
    static let maxOptions = 100
    /// How a list's entries are joined when substituted into a prompt.
    static let listSeparator = ", "

    var id: UUID
    var key: String
    var kind: Kind
    var defaultValue: String
    var description: String
    /// Entries of a `.list` variable, in order; the whole list is the value. Ignored for other kinds.
    var options: [String]

    init(id: UUID = UUID(), key: String, kind: Kind = .text, defaultValue: String = "", description: String = "", options: [String] = []) {
        self.id = id
        self.key = Self.sanitizeKey(key)
        self.kind = kind
        self.defaultValue = defaultValue
        self.description = description
        self.options = Self.normalizeOptions(options)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = Self.sanitizeKey(try c.decodeIfPresent(String.self, forKey: .key) ?? "")
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        options = Self.normalizeOptions(try c.decodeIfPresent([String].self, forKey: .options) ?? [])
    }

    /// The token to type or drop into a prompt.
    var placeholder: String { "{{\(key)}}" }

    /// The value a `.list` variable puts into the prompt: its entries joined by `listSeparator`.
    var listValue: String { Self.listValue(options) }

    static func listValue(_ entries: [String]) -> String {
        entries.joined(separator: listSeparator)
    }

    /// Trims, drops blanks and repeats, and keeps at most `maxOptions` entries.
    static func normalizeOptions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            output.append(trimmed)
            if output.count == maxOptions { break }
        }
        return output
    }

    /// Appends `values` that are not already entries, stopping at `maxOptions`. Returns what was added.
    @discardableResult
    mutating func addOptions(_ values: [String]) -> [String] {
        let before = options
        options = Self.normalizeOptions(options + values)
        return Array(options.dropFirst(before.count))
    }

    /// Keys are letters, digits, `_`, `.`, `-`; whitespace becomes `_`.
    static func sanitizeKey(_ raw: String) -> String {
        var output = ""
        for character in raw {
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                output.append(character)
            } else if character.isWhitespace, !output.hasSuffix("_") {
                output.append("_")
            }
        }
        return output.allSatisfy { $0 == "_" } ? "" : output
    }
}

/// A saved recipe: prompts + attached tools + run preferences.
nonisolated struct AgentTask: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var systemPrompt: String
    var userPrompt: String
    var toolAttachments: [ToolAttachment]
    /// Placeholders the prompts may reference; each has a default the user can override per run.
    var variables: [TaskVariable]
    /// Values last used for a run, keyed by variable key. Falls back to each variable's default.
    var variableValues: [String: String]
    /// When on, the run window shows a chat box and the model gets an `ask_user` tool.
    var allowsSteering: Bool
    /// What the task declares the model must be able to do. Tool calling is implied by attached tools
    /// and by steering, so it need not be listed; see `effectiveRequirements`.
    var requiredCapabilities: Set<ModelCapability>
    /// `ModelChoice.rawValue` last picked for this task.
    var preferredModel: String?
    /// Working-time limit for runs of this task, in seconds: nil follows the app setting, 0 means no limit.
    /// Like `preferredModel`, a choice made on this Mac that is never exported.
    var runTimeoutSeconds: Int?
    /// Generation settings (temperature, sampling, limits) per provider.
    var runOptions: RunOptions
    /// Unattended repeat, if the user set one. Cleared when steering is turned on.
    var schedule: TaskSchedule?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        systemPrompt: String = "",
        userPrompt: String = "",
        toolAttachments: [ToolAttachment] = [],
        variables: [TaskVariable] = [],
        variableValues: [String: String] = [:],
        allowsSteering: Bool = false,
        requiredCapabilities: Set<ModelCapability> = [],
        preferredModel: String? = nil,
        runTimeoutSeconds: Int? = nil,
        runOptions: RunOptions = RunOptions(),
        schedule: TaskSchedule? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.toolAttachments = toolAttachments
        self.variables = variables
        self.variableValues = variableValues
        self.allowsSteering = allowsSteering
        self.requiredCapabilities = requiredCapabilities
        self.preferredModel = preferredModel
        self.runTimeoutSeconds = runTimeoutSeconds
        self.runOptions = runOptions
        self.schedule = schedule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Spelled out because both the decoder and the encoder are written by hand.
    private enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, userPrompt, toolAttachments, variables, variableValues, allowsSteering
        case requiredCapabilities, preferredModel, runTimeoutSeconds, runOptions, schedule, createdAt, updatedAt
    }

    private enum LegacyKeys: String, CodingKey {
        case mcpServerIDs
    }

    /// Tolerant decoder so tasks saved before a field existed still load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        userPrompt = try c.decodeIfPresent(String.self, forKey: .userPrompt) ?? ""
        if let attachments = try c.decodeIfPresent([ToolAttachment].self, forKey: .toolAttachments) {
            toolAttachments = attachments
        } else {
            // Older files attached whole servers.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let ids = try legacy.decodeIfPresent([UUID].self, forKey: .mcpServerIDs) ?? []
            toolAttachments = ids.map { ToolAttachment(serverID: $0) }
        }
        variables = try c.decodeIfPresent([TaskVariable].self, forKey: .variables) ?? []
        variableValues = try c.decodeIfPresent([String: String].self, forKey: .variableValues) ?? [:]
        allowsSteering = try c.decodeIfPresent(Bool.self, forKey: .allowsSteering) ?? false
        // Names, not the enum, so a capability added by a newer build does not make the whole file unreadable.
        requiredCapabilities = ModelCapability.parse(try c.decodeIfPresent([String].self, forKey: .requiredCapabilities) ?? []).capabilities
        preferredModel = try c.decodeIfPresent(String.self, forKey: .preferredModel).map(ModelChoice.canonical)
        runTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .runTimeoutSeconds).map { max(RunTimeout.unlimited, $0) }
        runOptions = try c.decodeIfPresent(RunOptions.self, forKey: .runOptions) ?? RunOptions()
        schedule = try c.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Written by hand only so the capability set comes out in a stable order.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(userPrompt, forKey: .userPrompt)
        try c.encode(toolAttachments, forKey: .toolAttachments)
        try c.encode(variables, forKey: .variables)
        try c.encode(variableValues, forKey: .variableValues)
        try c.encode(allowsSteering, forKey: .allowsSteering)
        try c.encode(requiredCapabilities.sorted().map(\.rawValue), forKey: .requiredCapabilities)
        try c.encodeIfPresent(preferredModel, forKey: .preferredModel)
        try c.encodeIfPresent(runTimeoutSeconds, forKey: .runTimeoutSeconds)
        try c.encode(runOptions, forKey: .runOptions)
        try c.encodeIfPresent(schedule, forKey: .schedule)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    var displayName: String { name.isEmpty ? "Untitled Task" : name }

    /// Interactive tasks need a person at the keyboard, so they cannot be scheduled.
    var canBeScheduled: Bool { !allowsSteering }

    /// Interactive tasks wait on the person as long as it takes, so no time limit applies to them.
    var canHaveTimeLimit: Bool { !allowsSteering }

    /// IDs of every attached server.
    var mcpServerIDs: [UUID] { toolAttachments.map(\.serverID) }

    /// True when at least one tool is attached, i.e. the model may call tools.
    var usesTools: Bool { !toolAttachments.isEmpty }

    // MARK: - Model requirements

    /// Capabilities the task needs whether or not it says so: attached tools and the `ask_user` tool both need tool calling.
    var impliedCapabilities: Set<ModelCapability> {
        usesTools || allowsSteering ? [.tools] : []
    }

    /// Everything the model must support to run this task: the declared set plus what the tools imply.
    var effectiveRequirements: Set<ModelCapability> {
        requiredCapabilities.union(impliedCapabilities)
    }

    /// Requirements worth pointing out on their own: the declared ones that the tools do not already imply.
    var declaredRequirements: Set<ModelCapability> {
        requiredCapabilities.subtracting(impliedCapabilities)
    }

    func attachment(for serverID: UUID) -> ToolAttachment? {
        toolAttachments.first { $0.serverID == serverID }
    }

    /// `server__tool` identifiers mentioned in either prompt whose server prefix is attached.
    func referencedToolNames(servers: [MCPServerConfig]) -> [String] {
        let slugs = Set(servers.filter { mcpServerIDs.contains($0.id) }.map(\.slug))
        return Self.toolReferences(in: systemPrompt + "\n" + userPrompt).filter { name in
            guard let separator = name.range(of: "__") else { return false }
            return slugs.contains(String(name[..<separator.lowerBound]).lowercased())
        }
    }

    static let toolReferencePattern = #/([A-Za-z0-9][A-Za-z0-9_-]*?)__([A-Za-z0-9][A-Za-z0-9_.-]*)/#

    // MARK: - Variables

    /// Matches `{{key}}` (spaces inside the braces tolerated).
    static let variablePattern = #/\{\{\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*\}\}/#

    var variableKeys: Set<String> { Set(variables.map(\.key).filter { !$0.isEmpty }) }

    /// Effective value for every variable: the override if set, else the value from the last run, else the default.
    /// A list variable's value is its saved entries; edits made when running are saved onto the list itself.
    func resolvedVariableValues(overrides: [String: String] = [:]) -> [String: String] {
        var values: [String: String] = [:]
        for variable in variables where !variable.key.isEmpty {
            values[variable.key] = overrides[variable.key] ?? currentValue(for: variable)
        }
        return values
    }

    /// What the next run will use for `variable` if nothing is changed in the run sheet.
    func currentValue(for variable: TaskVariable) -> String {
        if variable.kind == .list { return variable.listValue }
        return variableValues[variable.key] ?? variable.defaultValue
    }

    /// True when the next run would fall back to the variable's default (never for lists: the list is the value).
    func usesDefault(_ variable: TaskVariable) -> Bool {
        variable.kind != .list && variableValues[variable.key] == nil
    }

    /// Replaces the entries of each list variable named in `lists` (normalised and capped).
    mutating func setListOptions(_ lists: [String: [String]]) {
        for index in variables.indices where variables[index].kind == .list {
            if let entries = lists[variables[index].key] {
                variables[index].options = TaskVariable.normalizeOptions(entries)
            }
        }
    }

    /// Replaces every `{{key}}` whose key is in `values`; unknown placeholders are left untouched.
    static func substitute(_ text: String, values: [String: String]) -> String {
        guard !values.isEmpty, text.contains("{{") else { return text }
        return text.replacing(variablePattern) { match in
            values[String(match.1)] ?? String(match.0)
        }
    }

    static func toolReferences(in text: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for match in text.matches(of: toolReferencePattern) {
            let name = String(match.0)
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }
}

/// A task being created or edited in the wizard. `isNew` tasks are not in the store until saved.
nonisolated struct TaskDraft: Identifiable, Hashable, Sendable {
    var task: AgentTask
    var isNew: Bool

    var id: UUID { task.id }
}
