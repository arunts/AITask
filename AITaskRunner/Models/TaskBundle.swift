import Foundation

/// A portable task file: prompts, steering, run options, tool attachments and the standard
/// `mcpServers` definitions those attachments rely on.
///
/// ```json
/// {
///   "format": "AITaskDefinition",
///   "version": 1,
///   "task": {
///     "name": "…", "systemPrompt": "…", "userPrompt": "…",
///     "allowsSteering": true,
///     "variables": [
///       { "key": "input_folder", "type": "folder", "default": "~/Downloads", "description": "Folder to summarise" },
///       { "key": "topics", "type": "list", "options": ["weather", "sport"] }
///     ],
///     "tools": [
///       { "builtin": "shell" },
///       { "server": "fetch", "tools": null }
///     ]
///   },
///   "mcpServers": { "fetch": { "command": "uvx", "args": ["mcp-server-fetch"] } }
/// }
/// ```
nonisolated enum TaskBundle {
    static let format = "AITaskDefinition"
    /// Format name written by earlier versions; still accepted on import.
    static let legacyFormats: Set<String> = ["oddjobs-task"]

    /// Bump only when the file schema itself changes shape.
    static let currentVersion = 1

    static let fileExtension = "json"

    enum BundleError: LocalizedError {
        case invalidJSON(String)
        case notATaskFile
        case unsupportedVersion(Int)
        case unknownBuiltin(String)
        case unknownBuiltinTools(pack: String, tools: [String])
        case missingServer(String)
        case invalidServers(String)
        case emptyPrompt

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail):
                return "Not valid JSON: \(detail)"
            case .notATaskFile:
                return "This is not a task definition file (expected \"format\": \"\(TaskBundle.format)\")."
            case .unsupportedVersion(let version):
                return "This task file is version \(version). This version of the app supports task files up to version \(TaskBundle.currentVersion). Update the app to import it."
            case .unknownBuiltin(let name):
                return "The task uses a built-in tool pack this version of the app does not have: “\(name)”."
            case .unknownBuiltinTools(let pack, let tools):
                return "The task uses built-in tools this version of the app does not have: \(tools.map { "\(pack)__\($0)" }.joined(separator: ", "))."
            case .missingServer(let slug):
                return "The task references MCP server “\(slug)” but the file does not define it under \"mcpServers\"."
            case .invalidServers(let detail):
                return "The \"mcpServers\" section is invalid: \(detail)"
            case .emptyPrompt:
                return "The task has no user prompt."
            }
        }
    }

    // MARK: - Export

    /// Serialises a task with the definitions of every attached MCP server.
    /// With `includeSecrets` off, environment variables and HTTP headers are left out.
    static func export(_ task: AgentTask, servers: [MCPServerConfig], includeSecrets: Bool) -> Data {
        var tools: [JSONValue] = []
        var definitions: [String: JSONValue] = [:]
        for attachment in task.toolAttachments {
            let selected: JSONValue = attachment.toolNames.map { .array($0.map { .string($0) }) } ?? .null
            if let pack = BuiltinToolPack(id: attachment.serverID) {
                tools.append(["builtin": .string(pack.rawValue), "tools": selected])
            } else if let server = servers.first(where: { $0.id == attachment.serverID }), server.transport != .builtin {
                tools.append(["server": .string(server.slug), "tools": selected])
                definitions[server.slug] = definition(for: server, includeSecrets: includeSecrets)
            }
        }

        let taskJSON: [String: JSONValue] = [
            "name": .string(task.displayName),
            "systemPrompt": .string(task.systemPrompt),
            "userPrompt": .string(task.userPrompt),
            "allowsSteering": .bool(task.allowsSteering),
            "variables": .array(task.variables.filter { !$0.key.isEmpty }.map { variable in
                var object: [String: JSONValue] = ["key": .string(variable.key)]
                if variable.kind != .text { object["type"] = .string(variable.kind.rawValue) }
                if variable.kind == .list {
                    object["options"] = .array(variable.options.map { .string($0) })
                } else {
                    object["default"] = .string(variable.defaultValue)
                }
                if !variable.description.isEmpty { object["description"] = .string(variable.description) }
                return .object(object)
            }),
            "tools": .array(tools),
        ]

        // Run options and the preferred model are deliberately left out: they are per-machine choices.
        let bundle: JSONValue = [
            "format": .string(format),
            "version": .number(Double(currentVersion)),
            "task": .object(taskJSON),
            "mcpServers": .object(definitions),
        ]
        return bundle.encoded(pretty: true)
    }

    private static func definition(for server: MCPServerConfig, includeSecrets: Bool) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(server.name)]
        switch server.transport {
        case .stdio:
            object["type"] = "stdio"
            object["command"] = .string(server.command)
            object["args"] = .array(MCPServerConfig.shellSplit(server.arguments).map { .string($0) })
            if includeSecrets, !server.parsedEnvironment.isEmpty {
                object["env"] = .object(server.parsedEnvironment.mapValues { .string($0) })
            }
        case .http:
            object["type"] = "http"
            object["url"] = .string(server.url)
            if includeSecrets, !server.parsedHeaders.isEmpty {
                object["headers"] = .object(server.parsedHeaders.mapValues { .string($0) })
            }
        case .builtin:
            break
        }
        return .object(object)
    }

    // MARK: - Import

    struct Imported {
        var task: AgentTask
        /// Servers defined in the file that are not configured yet (fresh IDs).
        var newServers: [MCPServerConfig]
        /// Servers the file defines that already exist here (matched by tool prefix); reused as-is.
        var reusedServers: [MCPServerConfig]
        var warnings: [String]
        var version: Int
    }

    static func parse(_ text: String, existingServers: [MCPServerConfig], builtinSettings: BuiltinToolSettings) throws -> Imported {
        let root: JSONValue
        do {
            root = try JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw BundleError.invalidJSON(error.localizedDescription)
        }
        guard let formatName = root["format"]?.string, formatName == format || legacyFormats.contains(formatName),
              let taskJSON = root["task"], taskJSON.object != nil else {
            throw BundleError.notATaskFile
        }
        let version = root["version"]?.int ?? 0
        guard version >= 1, version <= currentVersion else { throw BundleError.unsupportedVersion(version) }

        let userPrompt = taskJSON["userPrompt"]?.string ?? ""
        guard !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BundleError.emptyPrompt }

        // MCP definitions, via the same parser the Import-from-JSON sheet uses.
        var defined: [String: MCPServerConfig] = [:]
        if let servers = root["mcpServers"], let map = servers.object, !map.isEmpty {
            do {
                let wrapper = JSONValue.object(["mcpServers": servers])
                for server in try MCPServerImport.parse(String(decoding: wrapper.encoded(), as: UTF8.self)) {
                    defined[server.slug] = server
                }
            } catch {
                throw BundleError.invalidServers(error.localizedDescription)
            }
        }

        var attachments: [ToolAttachment] = []
        var newServers: [MCPServerConfig] = []
        var reused: [MCPServerConfig] = []
        var warnings: [String] = []

        for entry in taskJSON["tools"]?.array ?? [] {
            let names = entry["tools"]?.array?.compactMap(\.string)
            if let builtinName = entry["builtin"]?.string {
                guard let pack = BuiltinToolPack(slug: builtinName) else { throw BundleError.unknownBuiltin(builtinName) }
                if let names {
                    let known = Set(pack.tools.map(\.name))
                    let unknown = names.filter { !known.contains($0) }
                    if !unknown.isEmpty { throw BundleError.unknownBuiltinTools(pack: pack.config.slug, tools: unknown) }
                }
                if !builtinSettings.isEnabled(pack) {
                    warnings.append("The built-in \(pack.name) pack is turned off in Settings › Tools; turn it on before running.")
                }
                attachments.append(ToolAttachment(serverID: pack.id, toolNames: names))
            } else if let slug = entry["server"]?.string {
                if let existing = existingServers.first(where: { $0.slug == slug && $0.transport != .builtin }) {
                    if !reused.contains(where: { $0.id == existing.id }) { reused.append(existing) }
                    attachments.append(ToolAttachment(serverID: existing.id, toolNames: names))
                } else if let definition = defined[slug] {
                    if let added = newServers.first(where: { $0.slug == slug }) {
                        attachments.append(ToolAttachment(serverID: added.id, toolNames: names))
                    } else {
                        newServers.append(definition)
                        attachments.append(ToolAttachment(serverID: definition.id, toolNames: names))
                    }
                } else {
                    throw BundleError.missingServer(slug)
                }
            }
        }

        let variables: [TaskVariable] = (taskJSON["variables"]?.array ?? []).compactMap { entry in
            guard let key = entry["key"]?.string, !TaskVariable.sanitizeKey(key).isEmpty else { return nil }
            let kind = TaskVariable.Kind(rawValue: entry["type"]?.string ?? "text") ?? .text
            let rawOptions = entry["options"]?.array?.compactMap(\.string) ?? []
            let options = TaskVariable.normalizeOptions(rawOptions)
            if kind == .list, rawOptions.count > TaskVariable.maxOptions {
                warnings.append("Variable {{\(TaskVariable.sanitizeKey(key))}} lists \(rawOptions.count) values; only the first \(TaskVariable.maxOptions) were kept.")
            }
            return TaskVariable(
                key: key,
                kind: kind,
                defaultValue: kind == .list ? "" : (entry["default"]?.string ?? entry["defaultValue"]?.string ?? ""),
                description: entry["description"]?.string ?? "",
                options: options
            )
        }

        let task = AgentTask(
            name: taskJSON["name"]?.string ?? "",
            systemPrompt: taskJSON["systemPrompt"]?.string ?? "",
            userPrompt: userPrompt,
            toolAttachments: attachments,
            variables: variables,
            allowsSteering: taskJSON["allowsSteering"]?.bool ?? false
        )
        return Imported(task: task, newServers: newServers, reusedServers: reused, warnings: warnings, version: version)
    }
}
