import Foundation

/// One OpenAI-compatible server the user has connected: LM Studio, Ollama, llama.cpp, vLLM and the like.
/// Models are namespaced by the endpoint they were listed from, so two endpoints may serve the same model name.
nonisolated struct OpenAICompatibleEndpoint: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    /// Off: the endpoint keeps its settings but is not polled and its models are not offered.
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String = "", baseURL: String = "", apiKey: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isEnabled = isEnabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The namespace shown in pickers and run windows.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Endpoint" : trimmed
    }

    /// True once there is a base URL to try.
    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Presets

    struct Preset: Identifiable, Hashable, Sendable {
        let name: String
        let url: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "LM Studio", url: "http://localhost:1234/v1"),
        Preset(name: "Ollama", url: "http://localhost:11434/v1"),
        Preset(name: "llama.cpp or MLX server", url: "http://localhost:8080/v1"),
        Preset(name: "vLLM", url: "http://localhost:8000/v1"),
    ]

    /// The preset whose URL matches this endpoint, if any.
    var matchingPreset: Preset? {
        let current = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.presets.first { $0.url.lowercased() == current }
    }
}
