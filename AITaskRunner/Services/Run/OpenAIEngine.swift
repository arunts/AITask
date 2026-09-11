import Foundation

/// Drives an OpenAI-compatible endpoint through the tool-calling loop.
final class OpenAIEngine: RunEngine {
    private unowned let runner: TaskRunner
    private let toolbox: ToolBox
    private let client: OpenAICompatibleClient
    private let model: String
    private let parameters: [String: JSONValue]
    private let contextWindow: Int?
    private var messages: [JSONValue] = []
    private var callCounter = 0

    /// Prompt size the server reported for the previous request, and how many messages that request held.
    private var lastPromptTokens: Int?
    private var sentMessageCount = 0
    private var toolNamesByCallID: [String: String] = [:]

    private let maxToolResultCharacters = 60_000
    private let maxRounds = 50

    init(runner: TaskRunner, toolbox: ToolBox, client: OpenAICompatibleClient, model: String, systemPrompt: String, options: RunOptions.OpenAICompatibleOptions, contextWindow: Int?) {
        self.runner = runner
        self.toolbox = toolbox
        self.client = client
        self.model = model
        self.parameters = options.requestFields
        self.contextWindow = contextWindow
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            messages.append(["role": "system", "content": .string(trimmed)])
        }
    }

    func runTurn(userInput: String) async throws {
        messages.append(["role": "user", "content": .string(userInput)])
        var rounds = 0
        var retriedAfterOverflow = false
        while true {
            try Task.checkCancellation()
            rounds += 1
            if rounds > maxRounds {
                runner.addNotice("Stopped after \(maxRounds) consecutive tool-calling rounds.")
                return
            }

            trimIfNeeded()
            let turn: TurnResult
            do {
                turn = try await streamAssistantTurn()
            } catch where Self.isContextOverflow(error) && !retriedAfterOverflow {
                retriedAfterOverflow = true
                let dropped = trim(aggressively: true)
                guard dropped > 0 else {
                    throw OpenAICompatibleError.server("The model's context window is full and nothing older can be dropped. Shorten the prompts, attach fewer tools, or use a model with a larger window.")
                }
                runner.addNotice("The server rejected the request as too long. Dropped earlier thinking and \(dropped) older tool result\(dropped == 1 ? "" : "s"), retrying.")
                rounds -= 1
                continue
            }
            for call in turn.calls { toolNamesByCallID[call.id] = call.name }
            var assistant: [String: JSONValue] = ["role": "assistant", "content": .string(turn.text)]
            if !turn.thinking.isEmpty {
                assistant["reasoning_content"] = .string(turn.thinking)
            }
            if !turn.calls.isEmpty {
                assistant["tool_calls"] = .array(turn.calls.map { call in
                    [
                        "id": .string(call.id),
                        "type": "function",
                        "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
                    ]
                })
            }
            messages.append(.object(assistant))
            if turn.calls.isEmpty { return }

            for call in turn.calls {
                try Task.checkCancellation()
                let result = await toolbox.call(name: call.name, argumentsJSON: call.arguments, maxResultCharacters: maxToolResultCharacters)
                messages.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(result.text)])
            }
            for input in runner.dequeueInputs() {
                messages.append(["role": "user", "content": .string(input)])
            }
        }
    }

    // MARK: - Streaming one assistant message

    private struct PendingCall {
        var id: String
        var name: String
        var arguments: String
    }

    private struct TurnResult {
        var text: String
        var thinking: String
        var calls: [PendingCall]
    }

    private func streamAssistantTurn() async throws -> TurnResult {
        let block = runner.beginAssistant()
        var parser = ThinkTagParser()
        var calls: [PendingCall] = []
        var indexMap: [Int: Int] = [:]

        func finish() {
            let tail = parser.flush()
            block.text += tail.content
            block.thinking += tail.thinking
            runner.finishAssistant(block)
        }

        do {
            sentMessageCount = messages.count
            let stream = client.streamChat(model: model, messages: messages, tools: toolbox.openAIDefinitions, parameters: parameters)
            for try await event in stream {
                switch event {
                case .usage(let promptTokens, _):
                    lastPromptTokens = promptTokens
                    runner.reportContext(used: promptTokens, isExact: true)
                case .content(let chunk):
                    let parsed = parser.feed(chunk)
                    block.text += parsed.content
                    block.thinking += parsed.thinking
                case .reasoning(let chunk):
                    block.thinking += chunk
                case .toolCall(let index, let id, let name, let arguments):
                    let position: Int
                    if let index, let existing = indexMap[index] {
                        position = existing
                    } else if let id, !id.isEmpty, let existing = calls.firstIndex(where: { $0.id == id }) {
                        position = existing
                    } else {
                        callCounter += 1
                        calls.append(PendingCall(id: id ?? "call_\(callCounter)", name: name ?? "", arguments: ""))
                        position = calls.count - 1
                        if let index { indexMap[index] = position }
                    }
                    if let id, !id.isEmpty { calls[position].id = id }
                    if let name, !name.isEmpty, calls[position].name.isEmpty { calls[position].name = name }
                    calls[position].arguments += arguments
                case .finished:
                    break
                }
            }
        } catch {
            finish()
            throw error
        }
        finish()
        return TurnResult(text: block.text, thinking: block.thinking, calls: calls.filter { !$0.name.isEmpty })
    }

    // MARK: - Context budget

    /// Rough token estimate for messages the server has not counted yet.
    private static func estimateTokens(_ value: JSONValue) -> Int {
        value.compactString.count / 4 + 4
    }

    /// If the next request would likely exceed ~85% of the window, drop older thinking and stub older tool results.
    private func trimIfNeeded() {
        guard let contextWindow, contextWindow > 0, let lastPromptTokens else { return }
        let budget = Int(Double(contextWindow) * 0.85)
        let pending = messages[min(sentMessageCount, messages.count)...].reduce(0) { $0 + Self.estimateTokens($1) }
        guard lastPromptTokens + pending > budget else { return }
        let dropped = trim(aggressively: false, target: budget, projected: lastPromptTokens + pending)
        if dropped > 0 {
            runner.addNotice("Context nearly full: dropped earlier thinking and \(dropped) older tool result\(dropped == 1 ? "" : "s") from what is sent to the model.")
        }
    }

    /// Removes `reasoning_content` from older assistant messages and replaces older tool results with one-line stubs.
    /// The latest assistant turn and its results are kept intact. Returns how many tool results were stubbed.
    @discardableResult
    private func trim(aggressively: Bool, target: Int = 0, projected: Int = .max) -> Int {
        var projected = projected
        let lastAssistant = messages.lastIndex { $0["role"]?.string == "assistant" } ?? messages.count

        for index in messages.indices where index < lastAssistant {
            guard var object = messages[index].object, object["role"]?.string == "assistant",
                  let reasoning = object["reasoning_content"] else { continue }
            object["reasoning_content"] = nil
            messages[index] = .object(object)
            projected -= Self.estimateTokens(reasoning)
        }

        var stubbed = 0
        let minimumLength = aggressively ? 80 : 300
        for index in messages.indices where index < lastAssistant {
            if !aggressively, projected <= target { break }
            guard var object = messages[index].object, object["role"]?.string == "tool",
                  let content = object["content"]?.string, content.count > minimumLength,
                  !content.hasPrefix("[Earlier ") else { continue }
            let name = toolNamesByCallID[object["tool_call_id"]?.string ?? ""] ?? "tool"
            let stub = "[Earlier \(name) result omitted to fit the context window: \(content.count) characters]"
            object["content"] = .string(stub)
            messages[index] = .object(object)
            projected -= max(0, (content.count - stub.count) / 4)
            stubbed += 1
        }
        return stubbed
    }

    private static func isContextOverflow(_ error: any Error) -> Bool {
        let message: String
        switch error as? OpenAICompatibleError {
        case .http(let status, let body):
            guard [400, 413, 422, 500].contains(status) else { return false }
            message = body
        case .server(let text):
            message = text
        default:
            return false
        }
        let lowered = message.lowercased()
        return lowered.contains("context") || lowered.contains("too long") || lowered.contains("exceed")
            || lowered.contains("too many tokens") || lowered.contains("maximum length") || lowered.contains("n_ctx")
    }
}

/// Splits streamed content into visible text and `<think>…</think>` reasoning, tolerating tags that
/// arrive split across chunks.
nonisolated struct ThinkTagParser {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThink = false
    private var carry = ""
    private var trimLeadingWhitespace = false

    mutating func feed(_ chunk: String) -> (content: String, thinking: String) {
        var buffer = carry + chunk
        carry = ""
        var content = ""
        var thinking = ""

        while !buffer.isEmpty {
            let tag = inThink ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                let before = String(buffer[..<range.lowerBound])
                emit(before, into: &content, &thinking)
                buffer = String(buffer[range.upperBound...])
                inThink.toggle()
                if !inThink { trimLeadingWhitespace = true }
            } else {
                let hold = Self.partialSuffixLength(of: buffer, tag: tag)
                let splitIndex = buffer.index(buffer.endIndex, offsetBy: -hold)
                emit(String(buffer[..<splitIndex]), into: &content, &thinking)
                carry = String(buffer[splitIndex...])
                buffer = ""
            }
        }
        return (content, thinking)
    }

    mutating func flush() -> (content: String, thinking: String) {
        let remaining = carry
        carry = ""
        var content = ""
        var thinking = ""
        emit(remaining, into: &content, &thinking)
        return (content, thinking)
    }

    private mutating func emit(_ text: String, into content: inout String, _ thinking: inout String) {
        guard !text.isEmpty else { return }
        if inThink {
            thinking += text
        } else if trimLeadingWhitespace {
            let trimmed = text.drop { $0 == "\n" || $0 == " " || $0 == "\r" || $0 == "\t" }
            if !trimmed.isEmpty {
                trimLeadingWhitespace = false
                content += trimmed
            }
        } else {
            content += text
        }
    }

    /// Length of the longest proper prefix of `tag` that ends `text` (so we hold it back until the next chunk).
    private static func partialSuffixLength(of text: String, tag: String) -> Int {
        for length in stride(from: tag.count - 1, through: 1, by: -1) where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}
