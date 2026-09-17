import Foundation

/// Per-task generation settings, saved with the task. Every field is optional: `nil` means
/// "don't send it, let the provider use its default". Each provider has its own group because
/// the OpenAI-style API and Apple's `GenerationOptions` accept different knobs.
nonisolated struct RunOptions: Codable, Hashable, Sendable {
    var openAICompatible = OpenAICompatibleOptions()
    var apple = AppleOptions()

    /// Task files on disk still call the endpoint group `local`; keep reading and writing that name.
    private enum CodingKeys: String, CodingKey {
        case openAICompatible = "local"
        case apple
    }

    init(openAICompatible: OpenAICompatibleOptions = OpenAICompatibleOptions(), apple: AppleOptions = AppleOptions()) {
        self.openAICompatible = openAICompatible
        self.apple = apple
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openAICompatible = try container.decodeIfPresent(OpenAICompatibleOptions.self, forKey: .openAICompatible) ?? OpenAICompatibleOptions()
        apple = try container.decodeIfPresent(AppleOptions.self, forKey: .apple) ?? AppleOptions()
    }

    /// Settings that apply to the given model.
    func isDefault(for choice: ModelChoice) -> Bool {
        switch choice {
        case .appleFoundation: return apple.isDefault
        case .openAICompatible: return openAICompatible.isDefault
        }
    }

    func summary(for choice: ModelChoice) -> [String] {
        switch choice {
        case .appleFoundation: return apple.summary
        case .openAICompatible: return openAICompatible.summary
        }
    }

    // MARK: - OpenAI-compatible endpoints

    /// Knobs accepted by `/v1/chat/completions` on Ollama, LM Studio, llama.cpp, vLLM, mlx_lm and friends.
    nonisolated struct OpenAICompatibleOptions: Codable, Hashable, Sendable {
        var temperature: Double?
        var topP: Double?
        var maxTokens: Int?
        var seed: Int?
        var presencePenalty: Double?
        var frequencyPenalty: Double?
        var stopSequences: [String] = []
        /// Send only the latest reply's `reasoning_content`; older thinking is dropped before every request,
        /// whether or not the window is full. Applied by the engine, never sent to the server.
        var keepsLatestReasoningOnly = false

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            topP = try container.decodeIfPresent(Double.self, forKey: .topP)
            maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
            seed = try container.decodeIfPresent(Int.self, forKey: .seed)
            presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
            frequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
            stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences) ?? []
            keepsLatestReasoningOnly = try container.decodeIfPresent(Bool.self, forKey: .keepsLatestReasoningOnly) ?? false
        }

        var isDefault: Bool { self == OpenAICompatibleOptions() }

        /// Extra fields merged into the chat-completions request body.
        var requestFields: [String: JSONValue] {
            var fields: [String: JSONValue] = [:]
            if let temperature { fields["temperature"] = .number(max(0, temperature)) }
            if let topP { fields["top_p"] = .number(min(max(topP, 0), 1)) }
            if let maxTokens { fields["max_tokens"] = .number(Double(max(1, maxTokens))) }
            if let seed { fields["seed"] = .number(Double(seed)) }
            if let presencePenalty { fields["presence_penalty"] = .number(min(max(presencePenalty, -2), 2)) }
            if let frequencyPenalty { fields["frequency_penalty"] = .number(min(max(frequencyPenalty, -2), 2)) }
            let stops = stopSequences.filter { !$0.isEmpty }
            if !stops.isEmpty { fields["stop"] = .array(stops.map { .string($0) }) }
            return fields
        }

        var summary: [String] {
            var lines: [String] = []
            if let temperature { lines.append("temperature \(RunOptions.format(temperature))") }
            if let topP { lines.append("top_p \(RunOptions.format(topP))") }
            if let maxTokens { lines.append("max_tokens \(maxTokens)") }
            if let seed { lines.append("seed \(seed)") }
            if let presencePenalty { lines.append("presence_penalty \(RunOptions.format(presencePenalty))") }
            if let frequencyPenalty { lines.append("frequency_penalty \(RunOptions.format(frequencyPenalty))") }
            let stops = stopSequences.filter { !$0.isEmpty }
            if !stops.isEmpty { lines.append("stop \(stops.map { "“\($0)”" }.joined(separator: ", "))") }
            if keepsLatestReasoningOnly { lines.append("latest thinking only") }
            return lines
        }
    }

    // MARK: - Apple Foundation Models

    /// Knobs exposed by FoundationModels' `GenerationOptions`.
    nonisolated struct AppleOptions: Codable, Hashable, Sendable {
        nonisolated enum Sampling: String, Codable, Hashable, Sendable, CaseIterable {
            case greedy
            case topK
            case topP

            var label: String {
                switch self {
                case .greedy: return "Greedy (deterministic)"
                case .topK: return "Random · top K"
                case .topP: return "Random · top P (nucleus)"
                }
            }
        }

        var sampling: Sampling?
        var topK: Int?
        var topP: Double?
        var seed: Int?
        var temperature: Double?
        var maxResponseTokens: Int?

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sampling = try container.decodeIfPresent(Sampling.self, forKey: .sampling)
            topK = try container.decodeIfPresent(Int.self, forKey: .topK)
            topP = try container.decodeIfPresent(Double.self, forKey: .topP)
            seed = try container.decodeIfPresent(Int.self, forKey: .seed)
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            maxResponseTokens = try container.decodeIfPresent(Int.self, forKey: .maxResponseTokens)
        }

        var isDefault: Bool { self == AppleOptions() }

        var usesSeed: Bool { sampling == .topK || sampling == .topP }

        var summary: [String] {
            var lines: [String] = []
            switch sampling {
            case .greedy: lines.append("sampling greedy")
            case .topK: lines.append("sampling top-K \(max(1, topK ?? 40))")
            case .topP: lines.append("sampling top-P \(RunOptions.format(min(max(topP ?? 0.9, 0), 1)))")
            case nil: break
            }
            if usesSeed, let seed { lines.append("seed \(seed)") }
            if let temperature { lines.append("temperature \(RunOptions.format(temperature))") }
            if let maxResponseTokens { lines.append("max response tokens \(maxResponseTokens)") }
            return lines
        }
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
