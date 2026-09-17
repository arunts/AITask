import Foundation
import FoundationModels

nonisolated enum ToolBoxError: LocalizedError {
    case connectionFailed(server: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let server, let reason):
            return "Could not connect to MCP server “\(server)”: \(reason)"
        }
    }
}

/// The set of tools one run can call: attached MCP tools plus the built-in `ask_user`.
final class ToolBox {
    struct Entry: Identifiable {
        /// `serverSlug__toolName` — the identifier the model sees.
        let id: String
        let serverID: UUID
        let serverName: String
        let tool: MCPTool
        /// Set for native tools; nil for MCP tools.
        let pack: BuiltinToolPack?
    }

    static let askUserName = "ask_user"

    let entries: [Entry]
    let includesAskUser: Bool
    private let registry: MCPRegistry
    private weak var runner: TaskRunner?

    private init(entries: [Entry], includesAskUser: Bool, registry: MCPRegistry, runner: TaskRunner?) {
        self.entries = entries
        self.includesAskUser = includesAskUser
        self.registry = registry
        self.runner = runner
    }

    /// Connects every attached server (if needed) and collects their tools. Without a runner, notices are dropped.
    static func make(task: AgentTask, registry: MCPRegistry, runner: TaskRunner?) async throws -> ToolBox {
        var entries: [Entry] = []
        for attachment in task.toolAttachments {
            let serverID = attachment.serverID
            if let pack = BuiltinToolPack(id: serverID) {
                guard registry.builtinSettings.isEnabled(pack) else {
                    runner?.addNotice("Built-in \(pack.name) tools are turned off in Settings › Tools and were skipped.")
                    continue
                }
                let slug = pack.config.slug
                entries += pack.tools.filter { attachment.includes($0.name) }.map { tool in
                    Entry(id: "\(slug)__\(tool.name)", serverID: serverID, serverName: pack.name, tool: tool, pack: pack)
                }
                continue
            }
            guard let server = registry.server(id: serverID) else {
                runner?.addNotice("An attached MCP server no longer exists and was skipped.")
                continue
            }
            do {
                let connection = try await registry.ensureConnected(id: serverID)
                var tools = await connection.tools
                if let wanted = attachment.toolNames, wanted.contains(where: { name in !tools.contains { $0.name == name } }) {
                    // The cached list dates from the first connect; a tool added since is picked up without a reconnect.
                    await registry.refreshTools(id: serverID)
                    tools = await connection.tools
                }
                let selected = tools.filter { attachment.includes($0.name) }
                if let wanted = attachment.toolNames {
                    let missing = wanted.filter { name in !tools.contains { $0.name == name } }
                    if !missing.isEmpty {
                        runner?.addNotice("\(server.name) no longer offers: \(missing.joined(separator: ", "))")
                    }
                }
                entries += selected.map { tool in
                    Entry(id: "\(server.slug)__\(tool.name)", serverID: serverID, serverName: server.name, tool: tool, pack: nil)
                }
            } catch {
                throw ToolBoxError.connectionFailed(server: server.name, reason: error.localizedDescription)
            }
        }
        return ToolBox(entries: entries, includesAskUser: task.allowsSteering, registry: registry, runner: runner)
    }

    /// The id the model uses for the built-in context-clearing tool, when the task attaches it. The engine
    /// handles that call itself; `call` never runs it.
    var contextClearName: String? {
        entries.first { $0.pack == .context && $0.tool.name == ContextToolPack.clearToolName }?.id
    }

    var serverNames: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.serverName).inserted ? $0.serverName : nil }
    }

    // MARK: - Definitions for each provider

    static let askUserDefinition: JSONValue = [
        "type": "function",
        "function": [
            "name": .string(askUserName),
            "description": "Ask the user a question and wait for their answer. Use it when you need a decision, clarification or missing information before you can continue.",
            "parameters": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "The question to show the user."],
                ],
                "required": ["question"],
            ],
        ],
    ]

    var openAIDefinitions: [JSONValue] {
        var definitions = entries.map { entry -> JSONValue in
            [
                "type": "function",
                "function": [
                    "name": .string(entry.id),
                    "description": .string(entry.tool.description ?? ""),
                    "parameters": entry.tool.inputSchema,
                ],
            ]
        }
        if includesAskUser { definitions.append(Self.askUserDefinition) }
        return definitions
    }

    /// Foundation Models tools. Tools whose schema cannot be expressed, and the context-clearing tool (the
    /// framework owns the session's transcript), are reported in `skipped`.
    func foundationTools(maxResultCharacters: Int) -> (tools: [any Tool], skipped: [String]) {
        var tools: [any Tool] = []
        var skipped: [String] = []
        for entry in entries {
            if entry.pack == .context {
                skipped.append(entry.id)
                continue
            }
            do {
                let root = SchemaConverter.dynamicSchema(from: entry.tool.inputSchema, name: entry.id)
                let schema = try GenerationSchema(root: root, dependencies: [])
                tools.append(FMDynamicTool(
                    name: entry.id,
                    description: entry.tool.description ?? "MCP tool \(entry.tool.name)",
                    parameters: schema,
                    handler: { [self] json in
                        await self.call(name: entry.id, argumentsJSON: json, maxResultCharacters: maxResultCharacters).textDescribingImages
                    }
                ))
            } catch {
                skipped.append(entry.id)
            }
        }
        if includesAskUser {
            let root = SchemaConverter.dynamicSchema(
                from: Self.askUserDefinition["function"]?["parameters"] ?? [:],
                name: Self.askUserName
            )
            if let schema = try? GenerationSchema(root: root, dependencies: []) {
                tools.append(FMDynamicTool(
                    name: Self.askUserName,
                    description: Self.askUserDefinition["function"]?["description"]?.string ?? "",
                    parameters: schema,
                    handler: { [self] json in
                        await self.call(name: Self.askUserName, argumentsJSON: json, maxResultCharacters: maxResultCharacters).textDescribingImages
                    }
                ))
            }
        }
        return (tools, skipped)
    }

    // MARK: - Dispatch

    func call(name: String, argumentsJSON: String, maxResultCharacters: Int) async -> MCPToolResult {
        let arguments: JSONValue
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            arguments = [:]
        } else if let parsed = try? JSONValue.parse(trimmed), parsed.object != nil {
            arguments = parsed
        } else {
            return MCPToolResult(text: "Invalid JSON arguments: \(trimmed.prefix(200))", isError: true)
        }

        if name == Self.askUserName, includesAskUser {
            let question = arguments["question"]?.string ?? "The model needs your input to continue."
            guard let runner else { return MCPToolResult(text: "No user is available.", isError: true) }
            let answer = await runner.askUser(question)
            return MCPToolResult(text: answer, isError: false)
        }

        guard let entry = entries.first(where: { $0.id == name }) else {
            let block = runner?.beginToolCall(name: name, arguments: arguments.prettyString)
            let known = (entries.map(\.id) + (includesAskUser ? [Self.askUserName] : [])).joined(separator: ", ")
            let result = MCPToolResult(text: "Unknown tool “\(name)”. Available tools: \(known)", isError: true)
            if let block { runner?.finishToolCall(block, result: result) }
            return result
        }

        // Native tools that need a human in the loop pause here until the user decides.
        if let pack = entry.pack, pack.requiresApproval(entry.tool.name), registry.builtinSettings.shellRequiresApproval, let runner {
            let command = arguments["command"]?.string ?? arguments.compactString
            let directory = arguments["working_directory"]?.string
            let decision = await runner.requestApproval(toolName: name, command: command, detail: directory.map { "in \($0)" })
            if decision == .deny {
                let block = runner.beginToolCall(name: name, arguments: arguments.prettyString)
                let result = MCPToolResult(
                    text: "The user declined to run this command. Do not retry it unchanged; ask the user or take a different approach.",
                    isError: true
                )
                runner.finishToolCall(block, result: result)
                return result
            }
        }

        let block = runner?.beginToolCall(name: name, arguments: arguments.prettyString)
        var result: MCPToolResult
        if let pack = entry.pack {
            let settings = registry.builtinSettings
            switch pack {
            case .shell: result = await ShellToolPack.call(entry.tool.name, arguments: arguments, settings: settings)
            case .context: result = MCPToolResult(text: "\(name) is handled by the run engine and is not available on this model.", isError: true)
            case .progress:
                let (checked, progress) = ProgressToolPack.call(entry.tool.name, arguments: arguments)
                if let progress { runner?.reportProgress(progress) }
                result = checked
            }
        } else {
            do {
                let connection = try await registry.ensureConnected(id: entry.serverID)
                result = try await connection.callTool(name: entry.tool.name, arguments: arguments)
            } catch {
                result = MCPToolResult(text: "Tool call failed: \(error.localizedDescription)", isError: true)
            }
        }

        if result.text.count > maxResultCharacters {
            let overflow = result.text.count - maxResultCharacters
            result.text = String(result.text.prefix(maxResultCharacters)) + "\n… [truncated \(overflow) characters]"
        }
        Self.applyImageBudget(to: &result)
        if let block { runner?.finishToolCall(block, result: result) }
        return result
    }

    /// Decoded bytes of image data one tool result may carry to the model. Images are never cut by characters.
    static let imageBudgetBytes = 24 * 1024 * 1024

    /// Keeps images in order until the budget is spent; the first one that does not fit and every later one
    /// are dropped, and the text says how many.
    nonisolated static func applyImageBudget(to result: inout MCPToolResult, budget: Int = imageBudgetBytes) {
        var used = 0
        var kept: [MCPImage] = []
        for image in result.images {
            let bytes = image.decodedByteCount
            guard used + bytes <= budget else { break }
            used += bytes
            kept.append(image)
        }
        let dropped = result.images.count - kept.count
        guard dropped > 0 else { return }
        result.images = kept
        result.text += "\n[\(dropped) image(s) dropped: result exceeded the image budget]"
    }
}

// MARK: - Foundation Models bridging

/// A Foundation Models tool whose parameters come from a JSON Schema at runtime.
nonisolated struct FMDynamicTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let handler: @Sendable (String) async throws -> String

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        try await handler(arguments.jsonString)
    }
}

/// Converts (a practical subset of) JSON Schema into `DynamicGenerationSchema`.
nonisolated enum SchemaConverter {
    static func dynamicSchema(from schema: JSONValue, name: String) -> DynamicGenerationSchema {
        let safeName = sanitize(name)
        let description = schema["description"]?.string

        if let choices = schema["enum"]?.array?.compactMap(\.string), !choices.isEmpty {
            return DynamicGenerationSchema(name: safeName, description: description, anyOf: choices)
        }

        var type = schema["type"]?.string
        if type == nil, let types = schema["type"]?.array?.compactMap(\.string) {
            type = types.first { $0 != "null" }
        }
        if type == nil {
            type = schema["properties"] != nil ? "object" : (schema["items"] != nil ? "array" : "string")
        }

        switch type {
        case "object":
            let properties = schema["properties"]?.object ?? [:]
            let required = Set(schema["required"]?.array?.compactMap(\.string) ?? [])
            let converted = properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
                let propertySchema = properties[key] ?? ["type": "string"]
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: propertySchema["description"]?.string,
                    schema: dynamicSchema(from: propertySchema, name: "\(safeName)_\(key)"),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: safeName, description: description, properties: converted)
        case "array":
            let items = schema["items"] ?? ["type": "string"]
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(from: items, name: "\(safeName)_item"),
                minimumElements: schema["minItems"]?.int,
                maximumElements: schema["maxItems"]?.int
            )
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> String in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")) ? String(scalar) : "_"
        }.joined()
        return cleaned.isEmpty ? "Arguments" : cleaned
    }
}
