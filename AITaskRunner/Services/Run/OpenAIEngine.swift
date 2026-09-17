import Foundation

/// Drives an OpenAI-compatible endpoint through the tool-calling loop.
final class OpenAIEngine: RunEngine {
    private unowned let runner: TaskRunner
    private let toolbox: ToolBox
    private let client: OpenAICompatibleClient
    private let model: String
    private let parameters: [String: JSONValue]
    private let contextWindow: Int?
    /// Run option: strip older `reasoning_content` before every request, not only when the window is nearly full.
    private let keepsLatestReasoningOnly: Bool
    private var messages: [JSONValue] = []
    private var callCounter = 0
    /// The task prompt, kept verbatim across a context clear.
    private var firstUserMessage: JSONValue?
    /// Id of the built-in `context__clear` tool when the task attaches it; handled here, never sent to the toolbox.
    private let clearContextName: String?

    /// Prompt size the server reported for the previous request, and how many messages that request held.
    private var lastPromptTokens: Int?
    private var sentMessageCount = 0
    private var toolNamesByCallID: [String: String] = [:]

    /// Where a tool's images sit in `messages` (as a follow-up `user` message), so trimming can find them.
    nonisolated struct ImageMessageInfo: Sendable, Equatable {
        var toolName: String
        var count: Int
    }
    private var imageMessages: [Int: ImageMessageInfo] = [:]
    /// Set once the server has refused an image message; images are then described in text only for the rest of the run.
    private var imagesUnsupported = false
    /// The task declared it needs vision, so a refused image message ends the run instead of going text-only.
    private let requiresVision: Bool
    /// Capabilities this run has already reported to the runner, so each is noted once.
    private var noted: Set<ModelCapability> = []

    /// Rough token cost of one `image_url` part. Base64 length is never counted.
    nonisolated static let imageTokenEstimate = 1_500

    private let maxToolResultCharacters = 60_000
    private let maxRounds = 50

    init(runner: TaskRunner, toolbox: ToolBox, client: OpenAICompatibleClient, model: String, systemPrompt: String, options: RunOptions.OpenAICompatibleOptions, contextWindow: Int?, requiresVision: Bool = false) {
        self.runner = runner
        self.toolbox = toolbox
        self.client = client
        self.model = model
        self.parameters = options.requestFields
        self.keepsLatestReasoningOnly = options.keepsLatestReasoningOnly
        self.contextWindow = contextWindow
        self.requiresVision = requiresVision
        self.clearContextName = toolbox.contextClearName
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            messages.append(["role": "system", "content": .string(trimmed)])
        }
    }

    func runTurn(userInput: String) async throws {
        let userMessage: JSONValue = ["role": "user", "content": .string(userInput)]
        if firstUserMessage == nil { firstUserMessage = userMessage }
        messages.append(userMessage)
        var rounds = 0
        var retriedAfterOverflow = false
        while true {
            try Task.checkCancellation()
            rounds += 1
            if rounds > maxRounds {
                runner.addNotice("Stopped after \(maxRounds) consecutive tool-calling rounds.")
                return
            }

            if keepsLatestReasoningOnly { Self.dropEarlierReasoning(from: &messages) }
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
            } catch where Self.isImageRejection(error) && !imagesUnsupported && !imageMessages.isEmpty {
                // No settings toggle: the server's own answer decides whether this model takes images.
                runner.noteCapability(.vision, supported: false)
                if requiresVision { throw CapabilityError.imagesRejected(model: runner.modelTitle) }
                imagesUnsupported = true
                describeImageMessagesInText()
                runner.addNotice("This model does not accept images; tool images are described in text only.")
                rounds -= 1
                continue
            }
            for call in turn.calls { toolNamesByCallID[call.id] = call.name }
            if !turn.calls.isEmpty { note(.tools) }
            if !turn.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note(.thinking) }
            var assistant: [String: JSONValue] = ["role": "assistant", "content": .string(turn.text)]
            if !turn.thinking.isEmpty {
                assistant["reasoning_content"] = .string(turn.thinking)
            }
            if !turn.calls.isEmpty {
                assistant["tool_calls"] = .array(turn.calls.map(Self.toolCallJSON))
            }
            messages.append(.object(assistant))
            if turn.calls.isEmpty { return }

            for (position, call) in turn.calls.enumerated() {
                try Task.checkCancellation()
                if call.name == clearContextName {
                    if clearContext(call: call, remaining: Array(turn.calls[position...])) {
                        // A cleared conversation is as good as a new turn.
                        rounds = 0
                        retriedAfterOverflow = false
                    }
                    continue
                }
                let result = await toolbox.call(name: call.name, argumentsJSON: call.arguments, maxResultCharacters: maxToolResultCharacters)
                let content = imagesUnsupported ? result.textDescribingImages : result.text
                messages.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(content)])
                if !imagesUnsupported, !result.images.isEmpty {
                    // Tool messages take strings only; images go in a user message right after, as `image_url` parts.
                    imageMessages[messages.count] = ImageMessageInfo(toolName: call.name, count: result.images.count)
                    messages.append(Self.imageMessage(toolName: call.name, images: result.images))
                }
            }
            for input in runner.dequeueInputs() {
                messages.append(["role": "user", "content": .string(input)])
            }
        }
    }

    /// Tells the runner, once per run, that the model just showed it has a capability.
    private func note(_ capability: ModelCapability) {
        guard noted.insert(capability).inserted else { return }
        runner.noteCapability(capability, supported: true)
    }

    // MARK: - Streaming one assistant message

    nonisolated struct PendingCall: Sendable, Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    nonisolated static func toolCallJSON(_ call: PendingCall) -> JSONValue {
        [
            "id": .string(call.id),
            "type": "function",
            "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
        ]
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

    // MARK: - Clearing context on request

    /// Handles `context__clear`: keeps the system prompt, the task prompt, this round's remaining calls and the
    /// model's note; everything else is dropped. A blank note clears nothing and is answered with an error,
    /// so a model that forgets the note does not lose its state. Returns whether the context was cleared.
    private func clearContext(call: PendingCall, remaining: [PendingCall]) -> Bool {
        let arguments = (try? JSONValue.parse(call.arguments)) ?? [:]
        let block = runner.beginToolCall(name: call.name, arguments: arguments.prettyString)
        let note = arguments["note"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !note.isEmpty else {
            let result = MCPToolResult(text: ContextToolPack.blankNoteText, isError: true)
            runner.finishToolCall(block, result: result)
            messages.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(result.text)])
            return false
        }

        let (kept, dropped) = Self.cleared(messages: messages, firstUserMessage: firstUserMessage, call: call, remaining: remaining, note: note)
        messages = kept
        imageMessages.removeAll()
        toolNamesByCallID = toolNamesByCallID.filter { id, _ in remaining.contains { $0.id == id } }
        lastPromptTokens = nil
        sentMessageCount = 0

        let result = MCPToolResult(text: ContextToolPack.clearedResultText(dropped: dropped, note: note), isError: false)
        runner.finishToolCall(block, result: result)
        runner.addNotice("Context cleared: \(dropped) message\(dropped == 1 ? "" : "s") dropped. Only the system prompt, the task and the model's note are kept.")
        runner.reportContext(used: messages.reduce(0) { $0 + Self.estimateTokens($1) }, isExact: false)
        return true
    }

    /// The conversation after a clear: the system prompt (if any), the task prompt, one assistant message holding
    /// the clear call plus every call after it in the same round, and the clear's own result carrying the note.
    /// Results of calls earlier in that round go with everything else. `dropped` counts the messages removed.
    nonisolated static func cleared(
        messages: [JSONValue], firstUserMessage: JSONValue?, call: PendingCall, remaining: [PendingCall], note: String
    ) -> (messages: [JSONValue], dropped: Int) {
        var kept: [JSONValue] = []
        if let first = messages.first, first["role"]?.string == "system" { kept.append(first) }
        if let firstUserMessage { kept.append(firstUserMessage) }
        kept.append(["role": "assistant", "content": .string(""), "tool_calls": .array(remaining.map(toolCallJSON))])
        let dropped = max(0, messages.count - kept.count)
        kept.append([
            "role": "tool",
            "tool_call_id": .string(call.id),
            "content": .string(ContextToolPack.clearedResultText(dropped: dropped, note: note)),
        ])
        return (kept, dropped)
    }

    // MARK: - Images

    /// The follow-up `user` message that carries a tool's images to a vision model.
    nonisolated static func imageMessage(toolName: String, images: [MCPImage]) -> JSONValue {
        var parts: [JSONValue] = [["type": "text", "text": .string("Images returned by \(toolName) (\(images.count)):")]]
        for image in images {
            parts.append(["type": "image_url", "image_url": ["url": .string("data:\(image.mimeType);base64,\(image.base64)")]])
        }
        return ["role": "user", "content": .array(parts)]
    }

    /// What an image message becomes for a model that refused images.
    nonisolated static func textOnlyImageMessage(_ info: ImageMessageInfo) -> JSONValue {
        ["role": "user", "content": .string("[\(info.count) image(s) returned by \(info.toolName) are not shown: this model does not accept images]")]
    }

    /// Replaces every image message still carrying images with its text description.
    private func describeImageMessagesInText() {
        for (index, info) in imageMessages where messages.indices.contains(index) && messages[index]["content"]?.array != nil {
            messages[index] = Self.textOnlyImageMessage(info)
        }
        imageMessages.removeAll()
    }

    /// A 400/422 whose body blames images or the message content shape: the model (or server) has no vision input.
    nonisolated static func isImageRejection(_ error: any Error) -> Bool {
        guard case .http(let status, let body)? = error as? OpenAICompatibleError, status == 400 || status == 422 else { return false }
        let lowered = body.lowercased()
        return lowered.contains("image") || lowered.contains("vision") || lowered.contains("multimodal")
            || (lowered.contains("content") && lowered.contains("invalid"))
    }

    /// A 400/422 whose body says the model cannot take tools (Ollama: "… does not support tools").
    nonisolated static func isToolRejection(_ error: any Error) -> Bool {
        guard case .http(let status, let body)? = error as? OpenAICompatibleError, status == 400 || status == 422 else { return false }
        let lowered = body.lowercased()
        return lowered.contains("does not support tools") || lowered.contains("does not support tool")
            || lowered.contains("not support function calling") || lowered.contains("tools are not supported")
    }

    // MARK: - Context budget

    /// Rough token estimate for messages the server has not counted yet. Array content is counted per part,
    /// with a fixed cost per image, so base64 data never inflates the estimate.
    nonisolated static func estimateTokens(_ value: JSONValue) -> Int {
        guard let parts = value["content"]?.array else { return value.compactString.count / 4 + 4 }
        return parts.reduce(4) { total, part in
            if part["type"]?.string == "image_url" { return total + imageTokenEstimate }
            return total + (part["text"]?.string ?? part.compactString).count / 4
        }
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

    /// Removes `reasoning_content` from older assistant messages and replaces older tool results (and the
    /// image messages that follow them) with one-line stubs. The latest assistant turn and its results are
    /// kept intact. Returns how many tool results were stubbed.
    @discardableResult
    private func trim(aggressively: Bool, target: Int = 0, projected: Int = .max) -> Int {
        Self.trim(messages: &messages, imageMessages: imageMessages, toolNames: toolNamesByCallID,
                  aggressively: aggressively, target: target, projected: projected)
    }

    nonisolated static func trim(
        messages: inout [JSONValue],
        imageMessages: [Int: ImageMessageInfo],
        toolNames: [String: String],
        aggressively: Bool, target: Int = 0, projected: Int = .max
    ) -> Int {
        var projected = projected
        let lastAssistant = messages.lastIndex { $0["role"]?.string == "assistant" } ?? messages.count
        projected -= dropEarlierReasoning(from: &messages)

        var stubbed = 0
        let minimumLength = aggressively ? 80 : 300
        for index in messages.indices where index < lastAssistant {
            if !aggressively, projected <= target { break }
            guard var object = messages[index].object else { continue }
            if let info = imageMessages[index], object["content"]?.array != nil {
                // Stubs are strings, so a stubbed image message never matches again.
                object["content"] = .string("[Earlier \(info.count) image(s) from \(info.toolName) omitted to fit the context window]")
                messages[index] = .object(object)
                projected -= info.count * imageTokenEstimate
                stubbed += 1
                continue
            }
            guard object["role"]?.string == "tool",
                  let content = object["content"]?.string, content.count > minimumLength,
                  !content.hasPrefix("[Earlier ") else { continue }
            let name = toolNames[object["tool_call_id"]?.string ?? ""] ?? "tool"
            let stub = "[Earlier \(name) result omitted to fit the context window: \(content.count) characters]"
            object["content"] = .string(stub)
            messages[index] = .object(object)
            projected -= max(0, (content.count - stub.count) / 4)
            stubbed += 1
        }
        return stubbed
    }

    /// Removes `reasoning_content` from every assistant message except the latest one, which may hold the
    /// reasoning behind tool calls still being answered. Returns the estimated tokens freed.
    @discardableResult
    nonisolated static func dropEarlierReasoning(from messages: inout [JSONValue]) -> Int {
        let lastAssistant = messages.lastIndex { $0["role"]?.string == "assistant" } ?? messages.count
        var freed = 0
        for index in messages.indices where index < lastAssistant {
            guard var object = messages[index].object, object["role"]?.string == "assistant",
                  let reasoning = object["reasoning_content"] else { continue }
            object["reasoning_content"] = nil
            messages[index] = .object(object)
            freed += estimateTokens(reasoning)
        }
        return freed
    }

    nonisolated static func isContextOverflow(_ error: any Error) -> Bool {
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
