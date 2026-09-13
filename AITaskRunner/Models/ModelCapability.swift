import Foundation

/// Something a task can demand of the model that runs it. Three for now: calling tools, taking images
/// (from tool results) and reasoning before answering.
nonisolated enum ModelCapability: String, Codable, CaseIterable, Identifiable, Hashable, Sendable, Comparable {
    case tools
    case vision
    case thinking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tools: return "Tool calling"
        case .vision: return "Vision"
        case .thinking: return "Thinking"
        }
    }

    var symbol: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .vision: return "eye"
        case .thinking: return "brain"
        }
    }

    /// What the task gets from the capability, for the wizard and the import preview.
    var explanation: String {
        switch self {
        case .tools: return "The model can call the attached tools (and ask_user when the task is interactive)."
        case .vision: return "The model sees the images that tools return, instead of a text placeholder."
        case .thinking: return "The model reasons before it answers. Only reasoning models are offered."
        }
    }

    /// "no vision", for picker annotations.
    var negated: String { "no \(label.lowercased())" }

    static func < (lhs: ModelCapability, rhs: ModelCapability) -> Bool {
        let order = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    /// Reads capability names as written in task files or settings. Unknown names are dropped and returned.
    static func parse(_ names: [String]) -> (capabilities: Set<ModelCapability>, unknown: [String]) {
        var capabilities = Set<ModelCapability>()
        var unknown: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let capability = ModelCapability(rawValue: trimmed) {
                capabilities.insert(capability)
            } else if !trimmed.isEmpty {
                unknown.append(name)
            }
        }
        return (capabilities, unknown)
    }
}

extension Collection where Element == ModelCapability {
    /// "vision", "vision and thinking", "tool calling, vision and thinking".
    var listed: String {
        let labels = sorted().map { $0.label.lowercased() }
        switch labels.count {
        case 0: return ""
        case 1: return labels[0]
        default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }
}

/// Whether a model has a capability, as far as anyone knows.
nonisolated enum CapabilitySupport: Equatable, Sendable {
    case supported
    case unsupported
    /// The endpoint did not say and no run has shown it yet.
    case unknown

    var label: String {
        switch self {
        case .supported: return "Supported"
        case .unsupported: return "Not supported"
        case .unknown: return "Not reported"
        }
    }
}

/// What is known about one model's capabilities: the endpoint's report and what runs found out,
/// each entry remembering where it came from.
nonisolated struct CapabilityReport: Equatable, Sendable {
    nonisolated struct Entry: Equatable, Sendable {
        var support: CapabilitySupport
        /// "Ollama", "LM Studio", "a run"; nil when nothing is known.
        var source: String?

        static let unknown = Entry(support: .unknown, source: nil)
    }

    var entries: [ModelCapability: Entry] = [:]

    static let unknown = CapabilityReport()

    init() {}

    /// A report from one source that answers for every capability it names.
    init(supported: Set<ModelCapability>, unsupported: Set<ModelCapability>, source: String) {
        for capability in supported { entries[capability] = Entry(support: .supported, source: source) }
        for capability in unsupported where entries[capability] == nil { entries[capability] = Entry(support: .unsupported, source: source) }
    }

    subscript(capability: ModelCapability) -> Entry {
        entries[capability] ?? .unknown
    }

    /// True when nothing is known about any capability.
    var isEmpty: Bool { entries.isEmpty }

    /// Capabilities the model is known to lack, out of `requirements`.
    func unsupported(among requirements: Set<ModelCapability>) -> [ModelCapability] {
        requirements.filter { self[$0].support == .unsupported }.sorted()
    }

    /// Capabilities nobody has an answer for, out of `requirements`.
    func unreported(among requirements: Set<ModelCapability>) -> [ModelCapability] {
        requirements.filter { self[$0].support == .unknown }.sorted()
    }

    /// Whether the model may run a task with these requirements: nothing required is known to be missing.
    func satisfies(_ requirements: Set<ModelCapability>) -> Bool {
        unsupported(among: requirements).isEmpty
    }

    /// Records one answer, replacing whatever was there.
    mutating func set(_ capability: ModelCapability, supported: Bool, source: String) {
        entries[capability] = Entry(support: supported ? .supported : .unsupported, source: source)
    }
}
