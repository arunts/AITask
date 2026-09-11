import SwiftUI

struct TaskListView: View {
    @Binding var selection: UUID?
    @Environment(TaskStore.self) private var store
    @Environment(MCPRegistry.self) private var registry

    @State private var pendingDelete: AgentTask?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.tasks) { task in
                TaskRow(task: task)
                    .tag(task.id)
                    .contextMenu {
                        Button("Edit…") { store.beginEditing(id: task.id) }
                        Button("Duplicate") { store.duplicate(id: task.id) }
                        Button("Export…") { TaskExporter.save(task, registry: registry) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = task }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Task…") { store.beginNewTask() }
                    Button("Import Task…") { TaskImporter.chooseFile(store: store) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a task")
            }
        }
        .overlay {
            if store.tasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks Yet",
                    systemImage: "sparkles",
                    description: Text("Press ⌘N to create your first task.")
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProviderStatusFooter()
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) { store.delete(id: task.id) }
        } message: { _ in
            Text("This removes the saved task. Nothing else is affected.")
        }
    }
}

struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        Text(task.displayName)
            .textStyle(.body)
            .lineLimit(1)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .help(task.promptPreview)
    }
}

/// Model and tool status at the bottom of the sidebar, plus a Settings row. Clicking any row opens Settings.
struct ProviderStatusFooter: View {
    @Environment(ProviderHub.self) private var providers
    @Environment(MCPRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    /// Apple Intelligence and every endpoint folded into one line: what is usable right now.
    private var modelsSummary: (tone: StatusTone, text: String) {
        var sources: [String] = []
        if providers.foundation.isAvailable { sources.append("Apple Intelligence") }
        let statuses = settings.endpoints.map { providers.status(for: $0.id) }
        let modelCount = settings.endpoints.reduce(0) { $0 + providers.models(for: $1.id).count }
        if modelCount > 0 { sources.append(modelCount.counted("endpoint model")) }
        let offline = statuses.filter { if case .offline = $0 { return true } else { return false } }.count
        if !sources.isEmpty {
            if offline > 0 { sources.append(offline.counted("endpoint") + " offline") }
            return (.good, sources.joined(separator: " · "))
        }
        if statuses.contains(where: { $0 == .checking || $0 == .unknown }) { return (.pending, "Checking…") }
        return (.bad, "None connected")
    }

    private var toolsSummary: (tone: StatusTone, text: String) {
        let servers = registry.mcpServers
        let connected = servers.filter { registry.isConnected($0.id) }.count
        let failed = servers.filter {
            if case .failed = registry.state(for: $0.id) { return true }
            return false
        }.count
        let builtin = BuiltinToolPack.allCases.filter { registry.builtinSettings.isEnabled($0) }.count
        if servers.isEmpty {
            return builtin > 0 ? (.good, "Built-in only") : (.neutral, "None enabled")
        }
        if failed > 0 { return (.bad, "\(connected) connected · \(failed) failed") }
        if connected > 0 { return (.good, "\(connected) of \(servers.count.counted("server")) connected") }
        return (.neutral, "\(servers.count.counted("server")) · none connected")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                footerButton(tab: .models) {
                    statusLine(tone: modelsSummary.tone, title: "Models", detail: modelsSummary.text)
                }
                footerButton(tab: .tools) {
                    statusLine(tone: toolsSummary.tone, title: "Tools", detail: toolsSummary.text)
                }
            }
            .padding(.vertical, 4)
            Divider()
            footerButton(tab: .general) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Settings…").textStyle(.callout, weight: .semibold)
                }
            }
        }
        .overlay(alignment: .top) { Divider() }
    }

    private func footerButton<Content: View>(tab: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
        Button {
            settings.settingsTab = tab
            openSettings()
        } label: {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, tab == .general ? 10 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings")
    }

    private func statusLine(tone: StatusTone, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            StatusIcon(tone: tone)
                .textStyle(.callout)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).textStyle(.callout, weight: .semibold)
                Text(detail).textStyle(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
