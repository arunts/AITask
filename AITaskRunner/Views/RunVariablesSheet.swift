import AppKit
import SwiftUI

/// Asks for a value per variable right before a run. Prefilled with the last-used value or the default.
/// List variables show every entry and let you add or remove some; the edited list is handed back to be saved.
struct RunVariablesSheet: View {
    let task: AgentTask
    /// Called with the value per key (lists already joined) and, per list variable key, the full edited list.
    let onRun: (_ values: [String: String], _ lists: [String: [String]]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    /// Working copy of each list variable's entries, as edited in this sheet.
    @State private var lists: [String: [String]] = [:]
    /// Text typed into each list's "new value" field, by key.
    @State private var newEntries: [String: String] = [:]
    @FocusState private var focusedNewEntry: String?

    private var variables: [TaskVariable] {
        task.variables.filter { !$0.key.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(variables) { variable in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Label {
                                    Text(variable.placeholder)
                                        .textStyle(.body, design: .monospaced, weight: .semibold)
                                } icon: {
                                    Image(systemName: variable.kind.symbol)
                                }
                                if !variable.description.isEmpty {
                                    Text(variable.description)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if variable.kind != .list, binding(for: variable).wrappedValue != variable.defaultValue, !variable.defaultValue.isEmpty {
                                    Button("Use Default") { values[variable.key] = variable.defaultValue }
                                        .controlSize(.small)
                                        .help("Reset to “\(variable.defaultValue)”")
                                }
                            }
                            if variable.kind == .list {
                                listControls(for: variable)
                            } else {
                                HStack(spacing: 8) {
                                    TextField("Value", text: binding(for: variable), prompt: Text(variable.defaultValue.isEmpty ? "Enter a value" : variable.defaultValue))
                                        .labelsHidden()
                                        .controlSize(.large)
                                    if variable.kind.isPath {
                                        Button("Choose…") { choosePath(for: variable) }
                                            .controlSize(.large)
                                            .help(variable.kind == .folder ? "Choose a folder" : "Choose a file")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Values for this run")
                } footer: {
                    Text("Each {{variable}} in the prompts is replaced with its value before anything is sent to the model. A list becomes all its values separated by commas. What you enter here is remembered for the next run.")
                    .textStyle(.callout)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run") {
                    var final = values
                    for (key, entries) in lists { final[key] = TaskVariable.listValue(entries) }
                    onRun(final, lists)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 620)
        .frame(height: min(560, 170 + CGFloat(variables.count) * 92))
        .onAppear {
            values = task.resolvedVariableValues()
            for variable in variables where variable.kind == .list {
                lists[variable.key] = variable.options
            }
        }
    }

    // MARK: - List variables

    /// Every entry with a remove button, then a field to add one. The whole list is the value.
    @ViewBuilder
    private func listControls(for variable: TaskVariable) -> some View {
        let entries = lists[variable.key] ?? []
        let full = entries.count >= TaskVariable.maxOptions
        let draft = newEntries[variable.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            if entries.isEmpty {
                Text("No values yet. Add at least one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.self) { entry in
                HStack(spacing: 6) {
                    Text(entry)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        lists[variable.key]?.removeAll { $0 == entry }
                    } label: {
                        Label("Remove Value", systemImage: "minus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove “\(entry)” from this list")
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                TextField("New value", text: Binding(
                    get: { newEntries[variable.key] ?? "" },
                    set: { newEntries[variable.key] = $0 }
                ), prompt: Text(full ? "List is full" : "Add a value"))
                    .labelsHidden()
                    .controlSize(.large)
                    .focused($focusedNewEntry, equals: variable.key)
                    .disabled(full)
                    .onSubmit { addEntry(to: variable) }
                Button("Add") { addEntry(to: variable) }
                    .controlSize(.large)
                    .disabled(full || draft.isEmpty)
                    .help(full ? "This list already has \(TaskVariable.maxOptions) values" : "Add this value to the list")
                Text("\(entries.count) of \(TaskVariable.maxOptions)")
                    .textStyle(.callout)
                    .foregroundStyle(full ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
            }
            .padding(.top, 4)
        }
    }

    private func addEntry(to variable: TaskVariable) {
        let trimmed = (newEntries[variable.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = lists[variable.key] ?? []
        guard entries.count < TaskVariable.maxOptions else { return }
        if !entries.contains(trimmed) { entries.append(trimmed) }
        lists[variable.key] = entries
        newEntries[variable.key] = ""
        focusedNewEntry = variable.key
    }

    // MARK: - Helpers

    private func binding(for variable: TaskVariable) -> Binding<String> {
        Binding(
            get: { values[variable.key] ?? variable.defaultValue },
            set: { values[variable.key] = $0 }
        )
    }

    private func choosePath(for variable: TaskVariable) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = variable.kind == .folder
        panel.canChooseFiles = variable.kind == .file
        panel.allowsMultipleSelection = false
        panel.message = "Choose a \(variable.kind == .folder ? "folder" : "file") for \(variable.placeholder)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        values[variable.key] = url.path
    }
}
