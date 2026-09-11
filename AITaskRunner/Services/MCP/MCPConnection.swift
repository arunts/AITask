import Foundation

/// One live MCP session: initialize handshake, tool listing and tool calls with request/response matching.
actor MCPConnection {
    nonisolated let config: MCPServerConfig

    private var transport: (any MCPTransport)?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private(set) var tools: [MCPTool] = []
    private(set) var serverInfo: MCPServerInfo?

    private let onDisconnect: @Sendable (String) -> Void
    private let onToolsChanged: @Sendable ([MCPTool]) -> Void

    init(
        config: MCPServerConfig,
        onDisconnect: @escaping @Sendable (String) -> Void,
        onToolsChanged: @escaping @Sendable ([MCPTool]) -> Void
    ) {
        self.config = config
        self.onDisconnect = onDisconnect
        self.onToolsChanged = onToolsChanged
    }

    var isConnected: Bool { transport != nil }

    // MARK: - Lifecycle

    @discardableResult
    func connect() async throws -> [MCPTool] {
        if transport != nil { return tools }

        let newTransport: any MCPTransport
        switch config.transport {
        case .stdio: newTransport = MCPStdioTransport(config: config)
        case .http: newTransport = try MCPHTTPTransport(config: config)
        case .builtin: throw MCPError.launchFailed("Built-in tools run in-process and have no connection.")
        }

        try await newTransport.start(
            onMessage: { [weak self] message in
                Task { await self?.receive(message) }
            },
            onClose: { [weak self] reason in
                Task { await self?.transportDidClose(reason: reason) }
            }
        )
        transport = newTransport

        do {
            let result = try await request(
                "initialize",
                params: [
                    "protocolVersion": .string(MCP.protocolVersion),
                    "capabilities": [:],
                    "clientInfo": MCP.clientInfo,
                ],
                timeout: .seconds(60)
            )
            serverInfo = MCPServerInfo(initializeResult: result)
            try await newTransport.send(JSONRPC.notification(method: "notifications/initialized", params: nil))
            tools = try await fetchAllTools()
            return tools
        } catch {
            await teardown()
            throw error
        }
    }

    func disconnect() async {
        await teardown()
    }

    func refreshTools() async throws -> [MCPTool] {
        tools = try await fetchAllTools()
        return tools
    }

    // MARK: - Tool calls

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolResult {
        let result = try await request(
            "tools/call",
            params: ["name": .string(name), "arguments": arguments],
            timeout: .seconds(600)
        )
        let isError = result["isError"]?.bool ?? false
        var text = Self.flatten(content: result["content"])
        if text.isEmpty, let structured = result["structuredContent"] {
            text = structured.prettyString
        }
        return MCPToolResult(text: text, isError: isError)
    }

    static func flatten(content: JSONValue?) -> String {
        guard let items = content?.array else { return content?.textValue ?? "" }
        var parts: [String] = []
        for item in items {
            switch item["type"]?.string {
            case "text":
                parts.append(item["text"]?.string ?? "")
            case "image":
                parts.append("[image \(item["mimeType"]?.string ?? "")]")
            case "audio":
                parts.append("[audio \(item["mimeType"]?.string ?? "")]")
            case "resource":
                if let text = item["resource"]?["text"]?.string {
                    parts.append(text)
                } else {
                    parts.append("[resource \(item["resource"]?["uri"]?.string ?? "")]")
                }
            case "resource_link":
                parts.append("[resource link \(item["uri"]?.string ?? "")]")
            default:
                parts.append(item.compactString)
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - JSON-RPC plumbing

    private func fetchAllTools() async throws -> [MCPTool] {
        var collected: [MCPTool] = []
        var cursor: String?
        repeat {
            let params: JSONValue? = cursor.map { ["cursor": .string($0)] }
            let result = try await request("tools/list", params: params, timeout: .seconds(60))
            collected += (result["tools"]?.array ?? []).compactMap(MCPTool.init(json:))
            cursor = result["nextCursor"]?.string
        } while cursor != nil
        return collected
    }

    private func request(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        guard let transport else { throw MCPError.notConnected }
        let id = nextRequestID
        nextRequestID += 1
        let message = JSONRPC.request(id: id, method: method, params: params)

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.awaitResponse(id: id, sending: message, over: transport) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPError.timeout(method)
            }
            guard let value = try await group.next() else { throw MCPError.notConnected }
            group.cancelAll()
            return value
        }
    }

    private func awaitResponse(id: Int, sending message: JSONValue, over transport: any MCPTransport) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                Task {
                    do {
                        try await transport.send(message)
                    } catch {
                        self.fail(id: id, with: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, with: CancellationError()) }
        }
    }

    private func fail(id: Int, with error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func receive(_ message: JSONValue) {
        if let method = message["method"]?.string {
            if let id = message["id"] {
                // Server → client request. We only support ping.
                let reply = method == "ping"
                    ? JSONRPC.response(id: id, result: [:])
                    : JSONRPC.errorResponse(id: id, code: -32601, message: "AITaskRunner does not support \(method)")
                let transport = self.transport
                Task { try? await transport?.send(reply) }
            } else if method == "notifications/tools/list_changed" {
                Task {
                    if let updated = try? await self.refreshTools() {
                        self.onToolsChanged(updated)
                    }
                }
            }
            return
        }

        guard let id = message["id"]?.int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: MCPError.rpc(
                code: error["code"]?.int ?? -1,
                message: error["message"]?.string ?? error.compactString
            ))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func transportDidClose(reason: String) async {
        guard transport != nil else { return }
        await teardown()
        onDisconnect(reason)
    }

    private func teardown() async {
        let current = transport
        transport = nil
        tools = []
        for continuation in pending.values {
            continuation.resume(throwing: MCPError.transportClosed("connection closed"))
        }
        pending.removeAll()
        await current?.close()
    }
}
