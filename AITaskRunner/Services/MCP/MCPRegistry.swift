import Foundation
import Observation

/// Owns tool providers: the built-in packs (with their settings) and user-defined MCP servers
/// (persisted) plus their live connections (never persisted).
@Observable
final class MCPRegistry {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    /// User-defined MCP servers, in display order.
    private(set) var mcpServers: [MCPServerConfig] = []
    private(set) var states: [UUID: State] = [:]
    private(set) var tools: [UUID: [MCPTool]] = [:]
    private(set) var serverInfo: [UUID: MCPServerInfo] = [:]

    private var storedBuiltinSettings: BuiltinToolSettings
    private var connections: [UUID: MCPConnection] = [:]
    private let fileURL: URL
    private let builtinURL: URL
    private var saveTask: Task<Void, Never>?
    private var builtinSaveTask: Task<Void, Never>?

    init(directory: URL = AppPaths.supportDirectory, autoConnect: Bool = true) {
        fileURL = directory.appending(path: "mcp-servers.json")
        builtinURL = directory.appending(path: "builtin-tools.json")
        mcpServers = JSONFile.load([MCPServerConfig].self, from: fileURL) ?? []
        storedBuiltinSettings = JSONFile.load(BuiltinToolSettings.self, from: builtinURL) ?? BuiltinToolSettings()
        // Every configured server connects at launch; there is no per-server opt-in.
        guard autoConnect else { return }
        for server in mcpServers where server.isConfigured {
            Task { await connect(id: server.id) }
        }
    }

    // MARK: - Built-in packs

    var builtinSettings: BuiltinToolSettings {
        get { storedBuiltinSettings }
        set {
            guard newValue != storedBuiltinSettings else { return }
            storedBuiltinSettings = newValue
            scheduleBuiltinSave()
        }
    }

    /// Enabled built-in packs as pseudo-servers.
    var builtinServers: [MCPServerConfig] {
        BuiltinToolPack.allCases.filter { storedBuiltinSettings.isEnabled($0) }.map(\.config)
    }

    // MARK: - Lookup

    /// Everything a task can attach: enabled built-in packs first, then MCP servers.
    var servers: [MCPServerConfig] {
        builtinServers + mcpServers
    }

    func server(id: UUID) -> MCPServerConfig? {
        servers.first { $0.id == id }
    }

    func server(slug: String) -> MCPServerConfig? {
        servers.first { $0.slug == slug }
    }

    func state(for id: UUID) -> State {
        if let pack = BuiltinToolPack(id: id) {
            return storedBuiltinSettings.isEnabled(pack) ? .connected : .disconnected
        }
        return states[id] ?? .disconnected
    }

    func tools(for id: UUID) -> [MCPTool] {
        if let pack = BuiltinToolPack(id: id) { return pack.tools }
        return tools[id] ?? []
    }

    func isConnected(_ id: UUID) -> Bool {
        state(for: id) == .connected
    }

    // MARK: - Definitions

    @discardableResult
    func addServer() -> MCPServerConfig {
        let server = MCPServerConfig()
        mcpServers.append(server)
        scheduleSave()
        return server
    }

    /// Adds imported servers, renaming any whose tool prefix would clash with an existing provider,
    /// and connects the ones that are fully configured.
    func add(_ imported: [MCPServerConfig]) {
        var added: [MCPServerConfig] = []
        for var server in imported {
            var candidate = server.name
            var counter = 2
            while (servers + added).contains(where: { $0.slug == MCPServerConfig.slugify(candidate) }) {
                candidate = "\(server.name) \(counter)"
                counter += 1
            }
            server.name = candidate
            added.append(server)
        }
        mcpServers.append(contentsOf: added)
        scheduleSave()
        for server in added where server.isConfigured {
            Task { await connect(id: server.id) }
        }
    }

    func update(_ server: MCPServerConfig) {
        guard BuiltinToolPack(id: server.id) == nil,
              let index = mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        let previous = mcpServers[index]
        guard previous != server else { return }
        mcpServers[index] = server
        scheduleSave()
        if previous.connectionSignature != server.connectionSignature, connections[server.id] != nil {
            Task { await disconnect(id: server.id) }
        }
    }

    func remove(id: UUID) {
        guard BuiltinToolPack(id: id) == nil else { return }
        mcpServers.removeAll { $0.id == id }
        scheduleSave()
        Task { await disconnect(id: id) }
    }

    // MARK: - Connections

    func connect(id: UUID) async {
        guard BuiltinToolPack(id: id) == nil else { return }
        _ = try? await ensureConnected(id: id)
    }

    func disconnect(id: UUID) async {
        guard BuiltinToolPack(id: id) == nil else { return }
        guard let connection = connections.removeValue(forKey: id) else {
            states[id] = .disconnected
            return
        }
        await connection.disconnect()
        states[id] = .disconnected
        tools[id] = []
        serverInfo[id] = nil
    }

    /// Returns a connected session, connecting first if needed. Built-in packs have no session.
    func ensureConnected(id: UUID) async throws -> MCPConnection {
        guard BuiltinToolPack(id: id) == nil else {
            throw MCPError.launchFailed("Built-in tools run in-process and have no connection.")
        }
        // Wait if another caller is mid-connect.
        while state(for: id) == .connecting {
            try await Task.sleep(for: .milliseconds(100))
        }
        if let existing = connections[id], await existing.isConnected {
            return existing
        }
        guard let config = mcpServers.first(where: { $0.id == id }) else {
            throw MCPError.launchFailed("Server no longer exists.")
        }

        states[id] = .connecting
        let connection = MCPConnection(
            config: config,
            // The registry lives for the whole app; connections never outlive it.
            onDisconnect: { [unowned self] reason in
                Task { @MainActor in self.connectionDropped(id: id, reason: reason) }
            },
            onToolsChanged: { [unowned self] updated in
                Task { @MainActor in self.tools[id] = updated }
            }
        )
        connections[id] = connection
        do {
            let discovered = try await connection.connect()
            tools[id] = discovered
            serverInfo[id] = await connection.serverInfo
            states[id] = .connected
            return connection
        } catch {
            connections[id] = nil
            tools[id] = []
            states[id] = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshTools(id: UUID) async {
        guard let connection = connections[id] else { return }
        if let updated = try? await connection.refreshTools() {
            tools[id] = updated
        }
    }

    private func connectionDropped(id: UUID, reason: String) {
        connections[id] = nil
        tools[id] = []
        serverInfo[id] = nil
        states[id] = .failed(reason)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = mcpServers
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            JSONFile.save(snapshot, to: url)
        }
    }

    private func scheduleBuiltinSave() {
        builtinSaveTask?.cancel()
        let snapshot = storedBuiltinSettings
        let url = builtinURL
        builtinSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            JSONFile.save(snapshot, to: url)
        }
    }
}
