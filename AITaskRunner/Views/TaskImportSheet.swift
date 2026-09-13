import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// A task file the user picked, read into memory so the preview can parse it.
struct TaskImportSource: Identifiable {
    let id = UUID()
    let url: URL
    let text: String

    var fileName: String { url.lastPathComponent }
}

/// Opens the file panel; a readable file becomes `store.pendingImport`, which presents the preview sheet.
@MainActor
enum TaskImporter {
    static func chooseFile(store: TaskStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a task definition file (.\(TaskBundle.fileExtension))."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            store.pendingImport = TaskImportSource(url: url, text: try String(contentsOf: url, encoding: .utf8))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not read \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Preview of a chosen task file, laid out like the task summary, with one button to import it.
struct TaskImportSheet: View {
    let source: TaskImportSource

    @Environment(TaskStore.self) private var store
    @Environment(MCPRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    @State private var parsed: Result<TaskBundle.Imported, any Error>?

    private var imported: TaskBundle.Imported? { parsed.flatMap { try? $0.get() } }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            content
            Divider()
            HStack {
                Label(source.fileName, systemImage: "doc")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.url.path)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import Task") { importTask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(imported == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 720, idealHeight: 820)
        .task(id: source.id) {
            parsed = Result {
                try TaskBundle.parse(source.text, existingServers: registry.mcpServers, builtinSettings: registry.builtinSettings)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(imported?.task.displayName ?? "Import Task")
                .textStyle(.title2, weight: .semibold)
            if let imported {
                Text(imported.task.traits(toolCount: toolCount(imported)))
                    .foregroundStyle(.secondary)
            } else {
                Text("Review what the file contains before adding it to your tasks.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolCount(_ imported: TaskBundle.Imported) -> Int {
        imported.task.toolAttachments.reduce(0) { count, attachment in
            if let names = attachment.toolNames { return count + names.count }
            if let pack = BuiltinToolPack(id: attachment.serverID) { return count + pack.tools.count }
            return count
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch parsed {
        case .success(let imported)?:
            preview(imported)
        case .failure(let error)?:
            ContentUnavailableView {
                Label("Can’t Import This File", systemImage: "doc.badge.exclamationmark")
            } description: {
                Text(error.localizedDescription)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func preview(_ imported: TaskBundle.Imported) -> some View {
        let task = imported.task
        return Form {
            Section("System prompt") {
                if task.systemPrompt.isEmpty {
                    Text("None. The model gets only the user prompt.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(task.highlighted(task.systemPrompt, registry: registry))
                        .textSelection(.enabled)
                }
            }
            Section("User prompt") {
                Text(task.highlighted(task.userPrompt, registry: registry))
                    .textSelection(.enabled)
            }
            Section {
                toolRows(imported)
            } header: {
                Text("Tools")
            } footer: {
                toolsFooter(imported)
                    .textStyle(.callout)
            }
            if !task.variables.isEmpty {
                Section {
                    variableRows(task)
                } header: {
                    Text("Variables")
                } footer: {
                    Text("You are asked for these values each time you run the task.")
                        .textStyle(.callout)
                }
            }
            if task.allowsSteering {
                Section("Interactive") {
                    Label("The model can ask you questions while it runs.", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if !task.effectiveRequirements.isEmpty {
                Section {
                    ForEach(task.effectiveRequirements.sorted()) { capability in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capability.label)
                                Text(task.impliedCapabilities.contains(capability) && !task.requiredCapabilities.contains(capability)
                                     ? "Needed for the attached tools."
                                     : capability.explanation)
                                    .textStyle(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: capability.symbol)
                        }
                    }
                } header: {
                    Text("Model requirements")
                } footer: {
                    Text("Only models that support these are offered for the task; one known to lack any of them is not run.")
                        .textStyle(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func toolRows(_ imported: TaskBundle.Imported) -> some View {
        let task = imported.task
        if task.toolAttachments.isEmpty {
            Text("None. The model answers from the prompts alone.")
                .foregroundStyle(.secondary)
        } else {
            let servers = registry.servers + imported.newServers
            ForEach(task.toolAttachments) { attachment in
                if let server = servers.first(where: { $0.id == attachment.serverID }) {
                    let isNew = imported.newServers.contains { $0.id == server.id }
                    let names = attachment.toolNames ?? BuiltinToolPack(id: server.id)?.tools.map(\.name) ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent {
                            if server.transport == .builtin {
                                Text("Built in")
                            } else if isNew {
                                Text("Will be added")
                            } else {
                                Text("Already configured")
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(server.name) · \(attachment.includesAllTools ? "all tools" : names.count.counted("tool"))")
                                    if isNew {
                                        Text(server.summary)
                                            .textStyle(.callout, design: .monospaced)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            } icon: {
                                Image(systemName: server.transport == .builtin ? "shippingbox" : "network")
                            }
                        }
                        if !names.isEmpty {
                            Text(names.map { "\(server.slug)__\($0)" }.joined(separator: "   "))
                                .textStyle(.callout, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else if !attachment.includesAllTools {
                            Text("No tools selected.")
                                .textStyle(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolsFooter(_ imported: TaskBundle.Imported) -> some View {
        if imported.warnings.isEmpty {
            if !imported.newServers.isEmpty {
                Text("Servers marked “Will be added” are created in Settings › Tools when you import.")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(imported.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func variableRows(_ task: AgentTask) -> some View {
        ForEach(task.variables) { variable in
            let shown = variable.kind == .list ? variable.listValue : variable.defaultValue
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(shown.isEmpty ? "(empty)" : shown)
                        .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        .lineLimit(variable.kind == .list ? 4 : 2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if variable.kind != .list {
                        Text("default")
                            .textStyle(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variable.placeholder)
                            .textStyle(.body, design: .monospaced)
                            .foregroundStyle(.purple)
                        if !variable.description.isEmpty {
                            Text(variable.description)
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if variable.kind == .list {
                            Text(variable.options.count.counted("value"))
                                .textStyle(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: variable.kind.symbol)
                        .help(variable.kind.label)
                }
            }
        }
    }

    private func importTask() {
        guard let imported else { return }
        if !imported.newServers.isEmpty {
            registry.add(imported.newServers)
        }
        store.insert(imported.task)
        dismiss()
    }
}

/// Writes a task file via the save panel, with a checkbox for secrets.
@MainActor
enum TaskExporter {
    static func save(_ task: AgentTask, registry: MCPRegistry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(task.displayName).\(TaskBundle.fileExtension)"
        panel.message = "Export this task as a JSON file that another copy of the app can import."
        let hasSecrets = registry.mcpServers.contains { server in
            task.mcpServerIDs.contains(server.id) && (!server.environment.isEmpty || !server.headers.isEmpty)
        }
        let checkbox = NSButton(checkboxWithTitle: "Include environment variables and HTTP headers (may contain secrets)", target: nil, action: nil)
        checkbox.state = .off
        if hasSecrets {
            checkbox.sizeToFit()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.frame.width + 40, height: checkbox.frame.height + 20))
            checkbox.frame.origin = NSPoint(x: 20, y: 10)
            container.addSubview(checkbox)
            panel.accessoryView = container
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = TaskBundle.export(task, servers: registry.servers, includeSecrets: hasSecrets && checkbox.state == .on)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func copyToPasteboard(_ task: AgentTask, registry: MCPRegistry) {
        let data = TaskBundle.export(task, servers: registry.servers, includeSecrets: false)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}
