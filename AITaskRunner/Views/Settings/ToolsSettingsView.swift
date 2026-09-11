import AppKit
import SwiftUI

/// Settings › Tools: built-in packs first, then MCP servers.
struct ToolsSettingsView: View {
    @Environment(MCPRegistry.self) private var registry
    @State private var selection: UUID?
    @State private var showImport = false
    @State private var pendingRemoval: MCPServerConfig?
    @State private var newServerID: UUID?

    private var selectedServer: MCPServerConfig? {
        selection.flatMap { registry.server(id: $0) }.flatMap { $0.transport == .builtin ? nil : $0 }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            Group {
                if let selection, let pack = BuiltinToolPack(id: selection) {
                    BuiltinPackDetailView(pack: pack)
                        .id(pack.id)
                } else if let selection, let server = registry.server(id: selection) {
                    MCPServerDetailView(server: server, focusName: server.id == newServerID)
                        .id(server.id)
                } else {
                    ContentUnavailableView(
                        "Nothing Selected",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("Pick a built-in tool pack or an MCP server, or add a server with +.")
                    )
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = BuiltinToolPack.allCases.first?.id }
        }
        .sheet(isPresented: $showImport) {
            MCPImportSheet { imported in
                registry.add(imported)
                selection = registry.mcpServers.last?.id
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.name ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { server in
            Button("Remove", role: .destructive) {
                registry.remove(id: server.id)
                selection = BuiltinToolPack.allCases.first?.id
            }
        } message: { _ in
            Text("Tasks that use this server keep their reference and will report it as missing.")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Built-in") {
                ForEach(BuiltinToolPack.allCases) { pack in
                    let enabled = registry.builtinSettings.isEnabled(pack)
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pack.name).textStyle(.body).lineLimit(1)
                            Text(enabled ? pack.tools.count.counted("tool") : "Turned off")
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        StatusIcon(tone: enabled ? .good : .neutral)
                    }
                    .tag(pack.id)
                }
            }
            Section("MCP Servers") {
                if registry.mcpServers.isEmpty {
                    Text("None yet. Add one with +.")
                        .foregroundStyle(.secondary)
                }
                ForEach(registry.mcpServers) { server in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).textStyle(.body).lineLimit(1)
                            Text(server.summary)
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        StatusIcon(tone: registry.state(for: server.id).tone)
                    }
                    .tag(server.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    Button("New Server") {
                        let server = registry.addServer()
                        newServerID = server.id
                        selection = server.id
                    }
                    Button("Import from JSON…") { showImport = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add an MCP server by hand or from an mcpServers JSON block")
                Button {
                    pendingRemoval = selectedServer
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedServer == nil)
                .help(selectedServer == nil ? "Built-in packs cannot be removed; turn them off instead" : "Remove the selected server")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Settings for one built-in pack: enable switch, safety options and its tool list.
struct BuiltinPackDetailView: View {
    let pack: BuiltinToolPack

    @Environment(MCPRegistry.self) private var registry

    private var enabled: Binding<Bool> {
        Binding(
            get: { registry.builtinSettings.isEnabled(pack) },
            set: { on in
                switch pack {
                case .shell: registry.builtinSettings.shellEnabled = on
                }
            }
        )
    }

    var body: some View {
        @Bindable var registry = registry
        Form {
            Section {
                Toggle("Enabled", isOn: enabled)
            } header: {
                Text(pack.name)
            } footer: {
                Text("\(pack.description) Built-in tools run inside AITaskRunner and need nothing installed; attach them to a task like any MCP server.")
                .textStyle(.callout)
            }

            Section {
                Toggle("Ask before running each command", isOn: $registry.builtinSettings.shellRequiresApproval)
                LabeledContent("Timeout") {
                    Stepper(value: $registry.builtinSettings.shellTimeoutSeconds, in: 1...600) {
                        HStack(spacing: 4) {
                            TextField("Timeout", value: $registry.builtinSettings.shellTimeoutSeconds, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Text("seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Start in") {
                    HStack(spacing: 8) {
                        Text((registry.builtinSettings.workingDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(registry.builtinSettings.workingDirectory)
                        Button("Choose…") { chooseWorkingDirectory() }
                    }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Commands run in your login shell (/bin/zsh -l) and can reach anything your account can. With approval on, each command waits in the run window until you allow or deny it; “Allow All This Run” skips further prompts for that run only. Commands start in the folder above unless the model names another.")
                .textStyle(.callout)
            }

            Section {
                ForEach(pack.definitions, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pack.config.slug)__\(tool.name)")
                            .textStyle(.body, design: .monospaced)
                        Text(tool.description)
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            } header: {
                Text("Tools (\(pack.definitions.count))")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder shell commands start in."
        panel.directoryURL = URL(fileURLWithPath: registry.builtinSettings.resolvedWorkingDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registry.builtinSettings.workingDirectory = url.path
    }
}

struct MCPServerDetailView: View {
    let focusName: Bool

    @Environment(MCPRegistry.self) private var registry
    @State private var draft: MCPServerConfig
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    init(server: MCPServerConfig, focusName: Bool = false) {
        self.focusName = focusName
        _draft = State(initialValue: server)
    }

    private var state: MCPRegistry.State { registry.state(for: draft.id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .focused($nameFocused)
                Picker("Transport", selection: $draft.transport) {
                    ForEach(MCPServerConfig.Transport.userSelectable) { transport in
                        Text(transport.label).tag(transport)
                    }
                }
                switch draft.transport {
                case .stdio:
                    TextField("Command", text: $draft.command)
                    TextField("Arguments", text: $draft.arguments)
                    multilineField("Environment", text: $draft.environment)
                case .http:
                    TextField("URL", text: $draft.url)
                    multilineField("Headers", text: $draft.headers)
                case .builtin:
                    EmptyView()
                }
            } header: {
                Text("Server")
            } footer: {
                Group {
                    switch draft.transport {
                    case .stdio:
                        Text("The command runs through your login shell, so your PATH applies. Arguments are split like a shell: quotes and ~ work. Environment is one KEY=VALUE per line.")
                    case .http:
                        Text("URL of a Streamable HTTP MCP endpoint. Headers are one Header: Value per line, for example an Authorization header.")
                    case .builtin:
                        EmptyView()
                    }
                }
                .textStyle(.callout)
            }

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 12) {
                        StatusLabel(state.label, tone: state.tone)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                        Spacer()
                        if state == .connected {
                            Button("Disconnect") {
                                Task { await registry.disconnect(id: draft.id) }
                            }
                        } else {
                            Button(state == .connecting ? "Connecting…" : "Connect") {
                                flushSave()
                                Task { await registry.connect(id: draft.id) }
                            }
                            .disabled(state == .connecting)
                        }
                    }
                }
                if let info = registry.serverInfo[draft.id] {
                    LabeledContent("Server reports") {
                        Text("\(info.name) \(info.version) · protocol \(info.protocolVersion)")
                            .textSelection(.enabled)
                    }
                    if let instructions = info.instructions, !instructions.isEmpty {
                        LabeledContent("Instructions") {
                            Text(instructions)
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            let tools = registry.tools(for: draft.id)
            Section {
                if tools.isEmpty {
                    Text(state == .connected ? "This server exposes no tools." : "Tools appear once the server is connected. Configured servers connect when AITaskRunner launches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(draft.slug)__\(tool.name)")
                                .textStyle(.body, design: .monospaced)
                            if let description = tool.description, !description.isEmpty {
                                Text(description)
                                    .textStyle(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Tools (\(tools.count))")
                    Spacer()
                    if state == .connected {
                        Button("Refresh") { Task { await registry.refreshTools(id: draft.id) } }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { scheduleSave() }
        .onAppear { if focusName { nameFocused = true } }
        .onDisappear { flushSave() }
    }

    /// A monospaced multi-line field that sits inside a grouped form row.
    private func multilineField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextEditor(text: text)
                .textStyle(.body, design: .monospaced)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .padding(4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = draft
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            registry.update(snapshot)
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        registry.update(draft)
    }
}
