import Foundation

/// Which model executes a task. Endpoint models carry the ID of the endpoint they were listed from,
/// so two endpoints that both serve a model called "qwen3:8b" stay distinct.
nonisolated enum ModelChoice: Hashable, Sendable, Codable {
    case appleFoundation
    case openAICompatible(endpointID: UUID, model: String)

    static let applePrefix = "apple"
    /// `endpoint:<endpoint UUID>:<model id>`. The UUID has no colons, so the first colon after it ends the namespace.
    static let endpointPrefix = "endpoint:"
    /// Format saved before endpoints were namespaced: `local:<model id>`. Resolves to the endpoint migrated from those settings.
    static let legacyPrefix = "local:"
    /// ID given to the single endpoint that existed before multiple endpoints were supported.
    static let legacyEndpointID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    var rawValue: String {
        switch self {
        case .appleFoundation:
            return Self.applePrefix
        case .openAICompatible(let endpointID, let model):
            return Self.endpointPrefix + endpointID.uuidString + ":" + model
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.applePrefix {
            self = .appleFoundation
        } else if rawValue.hasPrefix(Self.endpointPrefix) {
            let rest = rawValue.dropFirst(Self.endpointPrefix.count)
            guard let separator = rest.firstIndex(of: ":"),
                  let endpointID = UUID(uuidString: String(rest[..<separator])) else { return nil }
            let model = String(rest[rest.index(after: separator)...])
            guard !model.isEmpty else { return nil }
            self = .openAICompatible(endpointID: endpointID, model: model)
        } else if rawValue.hasPrefix(Self.legacyPrefix) {
            let model = String(rawValue.dropFirst(Self.legacyPrefix.count))
            guard !model.isEmpty else { return nil }
            self = .openAICompatible(endpointID: Self.legacyEndpointID, model: model)
        } else {
            return nil
        }
    }

    /// Rewrites a stored raw value into the current format, leaving anything unparseable alone.
    static func canonical(_ rawValue: String) -> String {
        ModelChoice(rawValue: rawValue)?.rawValue ?? rawValue
    }

    var isApple: Bool {
        if case .appleFoundation = self { return true }
        return false
    }

    var endpointID: UUID? {
        if case .openAICompatible(let endpointID, _) = self { return endpointID }
        return nil
    }

    /// The model without its endpoint namespace. Use `AppSettings.displayName(for:)` when the namespace matters.
    var displayName: String {
        switch self {
        case .appleFoundation: return "Apple Foundation Model"
        case .openAICompatible(_, let model): return model
        }
    }
}

/// Value handed to the run window scene. Includes a fresh `runID` so every Run opens a new window.
nonisolated struct RunRequest: Codable, Hashable, Sendable {
    var runID: UUID
    var taskID: UUID
    var model: String
    /// Variable values chosen for this run (key → value).
    var variableValues: [String: String] = [:]
}
