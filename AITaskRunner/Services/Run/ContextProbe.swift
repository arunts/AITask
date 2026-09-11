import Foundation
import FoundationModels

/// Result of measuring the fixed part of a task's prompt: system prompt plus tool definitions.
nonisolated struct ContextMeasurement: Sendable, Equatable {
    var fixedTokens: Int
    var toolCount: Int
    var window: Int?
    var windowSource: String?
}

/// Measures the fixed prompt cost with the provider's own tokenizer.
/// OpenAI-compatible endpoint: a `max_tokens: 1` request whose `usage.prompt_tokens` is read back.
/// Apple: the framework's `tokenCount` for the instructions and the tool definitions.
enum ContextProbe {
    static func measure(task: AgentTask, model: ModelChoice, registry: MCPRegistry, providers: ProviderHub) async throws -> ContextMeasurement {
        let toolbox = try await ToolBox.make(task: task, registry: registry, runner: nil)
        let system = AgentTask.substitute(task.systemPrompt, values: task.resolvedVariableValues())
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch model {
        case .appleFoundation:
            let languageModel = SystemLanguageModel.default
            var tokens = 0
            if !system.isEmpty {
                tokens += try await languageModel.tokenCount(for: Instructions(system))
            }
            let (tools, _) = toolbox.foundationTools(maxResultCharacters: 4_000)
            if !tools.isEmpty {
                tokens += try await languageModel.tokenCount(for: tools)
            }
            return ContextMeasurement(fixedTokens: tokens, toolCount: tools.count, window: nil, windowSource: nil)

        case .openAICompatible(let endpointID, let id):
            let client = try providers.client(for: endpointID)
            var messages: [JSONValue] = []
            if !system.isEmpty { messages.append(["role": "system", "content": .string(system)]) }
            messages.append(["role": "user", "content": "."])
            let definitions = toolbox.openAIDefinitions
            let tokens = try await client.promptTokenCount(model: id, messages: messages, tools: definitions)
            let window = await providers.contextWindow(for: model)
            return ContextMeasurement(fixedTokens: tokens, toolCount: definitions.count, window: window?.tokens, windowSource: window?.source)
        }
    }
}
