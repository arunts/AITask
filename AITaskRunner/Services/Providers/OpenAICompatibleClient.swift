import Foundation

nonisolated enum ChatStreamEvent: Sendable {
    case content(String)
    case reasoning(String)
    case toolCall(index: Int?, id: String?, name: String?, arguments: String)
    case finished(reason: String?)
    /// Server-reported token usage for the whole request (usually on the final chunk).
    case usage(promptTokens: Int, completionTokens: Int?)
}

nonisolated enum OpenAICompatibleError: LocalizedError, Sendable {
    /// The endpoint named has no usable base URL.
    case invalidBaseURL(String)
    /// The model's endpoint was removed from Settings.
    case endpointMissing
    /// The endpoint named is turned off in Settings.
    case endpointDisabled(String)
    case invalidResponse
    case http(Int, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let endpoint): return "The base URL for “\(endpoint)” is not valid."
        case .endpointMissing: return "The endpoint this model came from is no longer in Settings › Models."
        case .endpointDisabled(let endpoint): return "“\(endpoint)” is turned off in Settings › Models."
        case .invalidResponse: return "The endpoint returned a non-HTTP response."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Endpoint returned HTTP \(status)" + (trimmed.isEmpty ? "." : ": \(trimmed.prefix(400))")
        case .server(let message): return message
        }
    }
}

/// Minimal client for any OpenAI-compatible `/v1` endpoint (LM Studio, Ollama, llama.cpp, vLLM…).
nonisolated struct OpenAICompatibleClient: Sendable {
    let baseURL: URL
    let apiKey: String

    init?(baseURLString: String, apiKey: String) {
        var text = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.timeoutInterval = 6
        applyHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: data)
        let json = try JSONValue.parse(data)
        let items = json["data"]?.array ?? json["models"]?.array ?? []
        return items
            .compactMap { $0["id"]?.string ?? $0["name"]?.string }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Streams a chat completion. Tool call fragments arrive incrementally and must be accumulated by the caller.
    func streamChat(
        model: String,
        messages: [JSONValue],
        tools: [JSONValue],
        parameters: [String: JSONValue] = [:]
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var body: [String: JSONValue] = [
                        "model": .string(model),
                        "messages": .array(messages),
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    if !tools.isEmpty {
                        body["tools"] = .array(tools)
                        body["tool_choice"] = "auto"
                    }
                    for (key, value) in parameters where body[key] == nil {
                        body[key] = value
                    }

                    var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 900
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    applyHeaders(to: &request)
                    request.httpBody = JSONValue.object(body).encoded()

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OpenAICompatibleError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 8192 { break }
                        }
                        throw OpenAICompatibleError.http(http.statusCode, Self.errorMessage(from: data))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONValue.parse(String(payload)) else { continue }
                        if let error = json["error"] {
                            throw OpenAICompatibleError.server(error["message"]?.string ?? error.textValue)
                        }
                        if let usage = json["usage"], let prompt = usage["prompt_tokens"]?.int {
                            continuation.yield(.usage(promptTokens: prompt, completionTokens: usage["completion_tokens"]?.int))
                        }
                        guard let choice = json["choices"]?.array?.first else { continue }
                        if let delta = choice["delta"] {
                            if let text = delta["content"]?.string, !text.isEmpty {
                                continuation.yield(.content(text))
                            }
                            if let reasoning = delta["reasoning_content"]?.string ?? delta["reasoning"]?.string,
                               !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            for call in delta["tool_calls"]?.array ?? [] {
                                continuation.yield(.toolCall(
                                    index: call["index"]?.int,
                                    id: call["id"]?.string,
                                    name: call["function"]?["name"]?.string,
                                    arguments: call["function"]?["arguments"]?.string ?? ""
                                ))
                            }
                        }
                        if let reason = choice["finish_reason"]?.string {
                            continuation.yield(.finished(reason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Context measurement

    /// Exact prompt size as the server tokenises it: sends the request with `max_tokens: 1` and reads `usage.prompt_tokens`.
    func promptTokenCount(model: String, messages: [JSONValue], tools: [JSONValue]) async throws -> Int {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
            "stream": false,
            "max_tokens": 1,
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = "auto"
        }
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        request.httpBody = JSONValue.object(body).encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, body: data)
        let json = try JSONValue.parse(data)
        guard let tokens = json["usage"]?["prompt_tokens"]?.int else {
            throw OpenAICompatibleError.server("The endpoint did not report token usage, so the context cannot be measured.")
        }
        return tokens
    }

    /// Asks the server how large the model's context window is, using whichever vendor endpoint answers.
    /// Returns nil when no endpoint reports it.
    func discoverContextWindow(model: String) async -> (tokens: Int, source: String)? {
        let root = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL

        // Ollama: /api/ps reports the context the loaded model actually runs with; /api/show the model's own maximum.
        if let show = await fetch(root.appending(path: "api/show"), body: ["model": .string(model)]) {
            if let ps = await fetch(root.appending(path: "api/ps")),
               let loaded = (ps["models"]?.array ?? []).first(where: { $0["name"]?.string == model || $0["model"]?.string == model }),
               let tokens = loaded["context_length"]?.int {
                return (tokens, "Ollama")
            }
            if let parameters = show["parameters"]?.string {
                for line in parameters.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.first == "num_ctx", let last = parts.last, let tokens = Int(last) {
                        return (tokens, "Ollama")
                    }
                }
            }
            if let info = show["model_info"]?.object,
               let key = info.keys.first(where: { $0.hasSuffix(".context_length") }),
               let tokens = info[key]?.int {
                return (tokens, "Ollama (model maximum; the loaded context may be smaller)")
            }
        }

        // LM Studio
        if let json = await fetch(root.appending(path: "api/v0/models")),
           let entry = (json["data"]?.array ?? []).first(where: { $0["id"]?.string == model }),
           let tokens = entry["loaded_context_length"]?.int ?? entry["max_context_length"]?.int {
            return (tokens, "LM Studio")
        }

        // llama.cpp server
        if let json = await fetch(root.appending(path: "props")),
           let tokens = json["default_generation_settings"]?["n_ctx"]?.int {
            return (tokens, "llama.cpp")
        }

        // vLLM and others that annotate /v1/models
        if let json = await fetch(baseURL.appending(path: "models")),
           let entry = (json["data"]?.array ?? []).first(where: { $0["id"]?.string == model }),
           let tokens = entry["max_model_len"]?.int ?? entry["context_length"]?.int {
            return (tokens, "endpoint")
        }
        return nil
    }

    // MARK: - Capabilities

    /// Asks the server what the model can do (tools, vision, thinking), using whichever vendor endpoint answers.
    /// Returns nil when no endpoint reports anything; a report may still leave some capabilities unknown.
    func discoverCapabilities(model: String) async -> CapabilityReport? {
        let root = baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL

        if let show = await fetch(root.appending(path: "api/show"), body: ["model": .string(model)]),
           let report = Self.capabilities(fromOllamaShow: show) {
            return report
        }
        if let json = await fetch(root.appending(path: "api/v1/models")),
           let report = Self.capabilities(fromLMStudio: json, model: model) {
            return report
        }
        if let json = await fetch(root.appending(path: "api/v0/models")),
           let report = Self.capabilities(fromLMStudio: json, model: model) {
            return report
        }
        if let props = await fetch(root.appending(path: "props")),
           let report = Self.capabilities(fromLlamaProps: props) {
            return report
        }
        return nil
    }

    /// Ollama's `/api/show` lists `capabilities` such as `completion`, `tools`, `vision`, `thinking`:
    /// what is absent from the list is not supported.
    nonisolated static func capabilities(fromOllamaShow show: JSONValue) -> CapabilityReport? {
        guard let names = show["capabilities"]?.array?.compactMap(\.string) else { return nil }
        let listed = Set(names.map { $0.lowercased() })
        let supported = Set(ModelCapability.allCases.filter { listed.contains($0.rawValue) })
        return CapabilityReport(supported: supported, unsupported: Set(ModelCapability.allCases).subtracting(supported), source: "Ollama")
    }

    /// LM Studio lists models under `data` (`/api/v0/models`, with `type` `llm`/`vlm`) or `models` (`/api/v1/models`,
    /// with a `capabilities` object or list). Only what the entry states is reported; the rest stays unknown.
    nonisolated static func capabilities(fromLMStudio json: JSONValue, model: String) -> CapabilityReport? {
        let entries = json["data"]?.array ?? json["models"]?.array ?? []
        guard let entry = entries.first(where: { $0["id"]?.string == model || $0["key"]?.string == model }) else { return nil }
        var supported = Set<ModelCapability>()
        var unsupported = Set<ModelCapability>()

        if let type = entry["type"]?.string?.lowercased() {
            if type == "vlm" {
                supported.insert(.vision)
            } else if type == "llm" {
                unsupported.insert(.vision)
            }
        }
        let aliases: [ModelCapability: [String]] = [
            .tools: ["tools", "tool_use", "trained_for_tool_use", "function_calling"],
            .vision: ["vision", "image_input"],
            .thinking: ["thinking", "reasoning"],
        ]
        if let object = entry["capabilities"]?.object {
            for (capability, keys) in aliases {
                for key in keys {
                    if let value = object[key]?.bool {
                        if value { supported.insert(capability) } else { unsupported.insert(capability) }
                    }
                }
            }
        } else if let list = entry["capabilities"]?.array?.compactMap(\.string) {
            let listed = Set(list.map { $0.lowercased() })
            for (capability, keys) in aliases {
                if keys.contains(where: { listed.contains($0) }) { supported.insert(capability) } else { unsupported.insert(capability) }
            }
        }
        unsupported.subtract(supported)
        guard !supported.isEmpty || !unsupported.isEmpty else { return nil }
        return CapabilityReport(supported: supported, unsupported: unsupported, source: "LM Studio")
    }

    /// llama.cpp's `/props` reports `modalities.vision`; nothing about tools or thinking.
    nonisolated static func capabilities(fromLlamaProps props: JSONValue) -> CapabilityReport? {
        guard let vision = props["modalities"]?["vision"]?.bool else { return nil }
        return CapabilityReport(supported: vision ? [.vision] : [], unsupported: vision ? [] : [.vision], source: "llama.cpp")
    }

    private func fetch(_ url: URL, body: JSONValue? = nil) async -> JSONValue? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        applyHeaders(to: &request)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encoded()
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONValue.parse(data)
    }

    // MARK: - Helpers

    private func applyHeaders(to request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenAICompatibleError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.http(http.statusCode, errorMessage(from: body))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONValue.parse(data) {
            if let message = json["error"]?["message"]?.string { return message }
            if let message = json["error"]?.string { return message }
            if let message = json["message"]?.string { return message }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
