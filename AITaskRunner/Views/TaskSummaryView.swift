import SwiftUI

/// Read-only overview of the selected task. Model, run options and Run live in the toolbar.
struct TaskSummaryView: View {
    let task: AgentTask

    @Environment(TaskStore.self) private var store
    @Environment(MCPRegistry.self) private var registry
    @Environment(ProviderHub.self) private var providers
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(TaskScheduler.self) private var scheduler

    @State private var confirmDelete = false
    @State private var showRunSheet = false
    @State private var measure: MeasureState = .idle

    private enum MeasureState: Equatable {
        case idle
        case measuring
        case measured(ContextMeasurement)
        case failed(String)
    }

    // MARK: - Derived

    private var selectedModel: String { task.preferredModel ?? "" }

    private var selectedChoice: ModelChoice? {
        guard let choice = ModelChoice(rawValue: selectedModel), providers.choices.contains(choice) else { return nil }
        return choice
    }

    /// Requirements the selected model is known not to meet.
    private var missingCapabilities: [ModelCapability] {
        guard let selectedChoice else { return [] }
        return providers.knownCapabilities(for: selectedChoice).unsupported(among: task.effectiveRequirements)
    }

    /// Requirements nobody has an answer for with the selected model.
    private var unreportedCapabilities: [ModelCapability] {
        guard let selectedChoice else { return [] }
        return providers.knownCapabilities(for: selectedChoice).unreported(among: task.effectiveRequirements)
    }

    private var canRun: Bool {
        selectedChoice != nil
            && !task.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && missingCapabilities.isEmpty
    }

    private var runHelp: String {
        if canRun { return "Run this task (⌘R)" }
        if let selectedChoice, !missingCapabilities.isEmpty {
            return "\(selectedChoice.displayName) does not support \(missingCapabilities.listed)"
        }
        return "Pick an available model to run"
    }

    /// Writes the picked model straight into the stored task.
    private var modelSelection: Binding<String> {
        Binding(
            get: { selectedModel },
            set: { newValue in
                guard var stored = store.task(id: task.id) else { return }
                stored.preferredModel = newValue.isEmpty ? nil : newValue
                store.update(stored)
            }
        )
    }

    /// Edits run options in place (they are not part of the wizard).
    private var runOptions: Binding<RunOptions> {
        Binding(
            get: { store.task(id: task.id)?.runOptions ?? task.runOptions },
            set: { newValue in
                guard var stored = store.task(id: task.id) else { return }
                stored.runOptions = newValue
                store.update(stored)
            }
        )
    }

    private var subtitle: String {
        let traits = task.traits(toolCount: registry.callableToolNames(for: task).count)
        return "\(traits) · Updated \(task.updatedAt.formatted(.relative(presentation: .named)))"
    }

    /// Everything that, when changed, requires measuring the context again.
    private struct MeasureKey: Hashable {
        var taskID: UUID
        var model: String
        var systemPrompt: String
        var attachments: [ToolAttachment]
        var variables: [TaskVariable]
        var steering: Bool
        var windowOverride: Int?
    }

    private var measureKey: MeasureKey {
        MeasureKey(
            taskID: task.id, model: selectedModel, systemPrompt: task.systemPrompt,
            attachments: task.toolAttachments, variables: task.variables, steering: task.allowsSteering,
            windowOverride: selectedChoice.flatMap { choice in
                if case .openAICompatible = choice { return settings.contextWindows[choice.rawValue] }
                return nil
            }
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupedSection("System prompt") {
                    Group {
                        if task.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("None. The model runs with the provider's default behaviour.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(task.highlighted(task.systemPrompt, registry: registry))
                                .textSelection(.enabled)
                        }
                    }
                    .groupedRow()
                }
                GroupedSection("User prompt") {
                    Text(task.highlighted(task.userPrompt, registry: registry))
                        .textSelection(.enabled)
                        .groupedRow()
                }
                GroupedSection {
                    toolRows
                } header: {
                    Text("Tools")
                } footer: {
                    referenceSummary
                        .textStyle(.callout)
                }
                if !task.effectiveRequirements.isEmpty {
                    GroupedSection {
                        requirementRows
                    } header: {
                        Text("Model requirements")
                    } footer: {
                        requirementsFootnote
                            .textStyle(.callout)
                    }
                }
                if !task.variables.isEmpty {
                    GroupedSection {
                        variableRows
                    } header: {
                        Text("Variables")
                    } footer: {
                        Text("You are asked for these values each time you run the task.")
                        .textStyle(.callout)
                    }
                }
                if task.canBeScheduled {
                    // Relative times go stale, so the section re-renders every minute.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        GroupedSection {
                            scheduleRows
                        } header: {
                            Text("Schedule")
                        } footer: {
                            scheduleFootnote
                                .textStyle(.callout)
                        }
                    }
                }
                GroupedSection {
                    contextRows
                } header: {
                    Text("Context")
                } footer: {
                    contextFootnote
                        .textStyle(.callout)
                }
            }
            .padding(20)
        }
        .navigationTitle(task.displayName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .task(id: measureKey) { await measureContext() }
        .task(id: selectedModel) {
            // Make sure the endpoint has been asked about this model, so the requirement rows are not stuck on "Not reported".
            if let choice = selectedChoice, !task.effectiveRequirements.isEmpty {
                _ = await providers.capabilities(for: choice)
            }
        }
        .onChange(of: providers.choices) { pickDefaultModelIfNeeded() }
        .onAppear { pickDefaultModelIfNeeded() }
        .sheet(isPresented: $showRunSheet) {
            RunVariablesSheet(task: task) { values, lists in
                launch(values: values, lists: lists)
            }
        }
        .confirmationDialog("Delete “\(task.displayName)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(id: task.id) }
        } message: {
            Text("This removes the saved task. Nothing else is affected.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var toolRows: some View {
        if task.toolAttachments.isEmpty {
            Text("None. The model answers from the prompts alone.")
                .foregroundStyle(.secondary)
                .groupedRow()
        } else {
            ForEach(Array(task.toolAttachments.enumerated()), id: \.element.id) { index, attachment in
                if index > 0 { Divider().padding(.leading, 12) }
                if let server = registry.server(id: attachment.serverID) {
                    let state = registry.state(for: server.id)
                    let names = attachment.toolNames ?? registry.tools(for: server.id).map(\.name)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent {
                            if state == .connected || server.transport == .builtin {
                                Text(attachment.includesAllTools ? "All tools" : names.count.counted("tool"))
                            } else {
                                Text(state.label)
                            }
                        } label: {
                            StatusLabel(server.name, tone: state.tone)
                        }
                        if names.isEmpty {
                            Text(state == .connected ? "This server exposes no tools." : "The tool list appears once the server connects.")
                                .textStyle(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(names.map { "\(server.slug)__\($0)" }.joined(separator: "   "))
                                .textStyle(.callout, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .groupedRow()
                } else {
                    Label("An attached server no longer exists. Edit the task to remove it.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .groupedRow()
                }
            }
        }
    }

    @ViewBuilder
    private var referenceSummary: some View {
        let references = task.referencedToolNames(servers: registry.servers)
        let known = Set(registry.callableToolNames(for: task).map { $0.lowercased() })
        let unknown = references.filter { !known.contains($0.lowercased()) }
        if task.toolAttachments.isEmpty {
            EmptyView()
        } else if references.isEmpty {
            Text("The prompts do not name a tool; the model may still call any attached tool.")
        } else {
            let listed = references.joined(separator: ", ")
            if unknown.isEmpty || !registry.servers.contains(where: { task.mcpServerIDs.contains($0.id) && registry.isConnected($0.id) }) {
                Text("The prompts name \(references.count.counted("tool")): \(listed).")
            } else {
                Text("The prompts name \(references.count.counted("tool")): \(listed). Not among the attached tools: \(unknown.joined(separator: ", ")).")
                    .foregroundStyle(.red)
            }
        }
    }

    private var requirementRows: some View {
        let requirements = task.effectiveRequirements.sorted()
        return ForEach(Array(requirements.enumerated()), id: \.element) { index, capability in
            if index > 0 { Divider().padding(.leading, 12) }
            LabeledContent {
                if let choice = selectedChoice {
                    CapabilityStatusLabel(choice: choice, capability: capability)
                } else {
                    Text("Choose a model")
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capability.label)
                        if task.impliedCapabilities.contains(capability) {
                            Text(task.usesTools ? "Needed for the attached tools" : "Needed for the ask_user tool")
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: capability.symbol)
                }
            }
            .groupedRow()
        }
    }

    @ViewBuilder
    private var requirementsFootnote: some View {
        if let choice = selectedChoice {
            if !missingCapabilities.isEmpty {
                Text("Run is off: \(choice.displayName) does not support \(missingCapabilities.listed). Pick another model.")
                    .foregroundStyle(.red)
            } else if !unreportedCapabilities.isEmpty {
                Text("The endpoint does not say whether \(choice.displayName) supports \(unreportedCapabilities.listed). The run goes ahead anyway.")
            } else {
                Text("What the model must support. Models known to lack any of it are marked in the picker and refused at run time.")
            }
        } else {
            Text("Choose a model in the toolbar to check it against these.")
        }
    }

    private var variableRows: some View {
        ForEach(Array(task.variables.enumerated()), id: \.element.id) { index, variable in
            let current = task.currentValue(for: variable)
            if index > 0 { Divider().padding(.leading, 12) }
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(current.isEmpty ? "(empty)" : current)
                        .foregroundStyle(current.isEmpty ? .secondary : .primary)
                        .lineLimit(variable.kind == .list ? 4 : 2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if task.usesDefault(variable) {
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
            .groupedRow()
        }
    }

    @ViewBuilder
    private var scheduleRows: some View {
        if let schedule = task.schedule {
            LabeledContent("Repeats") {
                Text("Every \(schedule.intervalHours.counted("hour"))")
            }
            .groupedRow()
            Divider().padding(.leading, 12)
            LabeledContent("Last run") {
                if let last = schedule.lastRunAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                        if let outcome = schedule.lastOutcome {
                            let failed = { if case .failed = outcome { return true } else { return false } }()
                            Text(outcome.label)
                                .textStyle(.callout)
                                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                        }
                    }
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            .groupedRow()
            Divider().padding(.leading, 12)
            LabeledContent("Next run") {
                HStack(spacing: 8) {
                    if scheduler.isRunning(task.id) {
                        ProgressView().controlSize(.small)
                        Text("Running now")
                        Button("Stop") { scheduler.stopActiveRun() }
                            .controlSize(.small)
                    } else if schedule.isDue(), let reason = scheduler.holdReason(for: task) {
                        Text(reason)
                            .foregroundStyle(.orange)
                    } else if schedule.isDue() {
                        Text("Any moment now")
                    } else {
                        Text("\(schedule.nextRunAt.formatted(.relative(presentation: .named))) · \(schedule.nextRunAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .groupedRow()
        } else {
            Text("Off. Edit the task to run it on a schedule.")
                .foregroundStyle(.secondary)
                .groupedRow()
        }
    }

    @ViewBuilder
    private var scheduleFootnote: some View {
        if task.schedule != nil {
            let model = task.preferredModel.flatMap { ModelChoice(rawValue: $0) }.map { settings.displayName(for: $0) } ?? "the chosen model"
            Text("Runs happen only while AITaskRunner is open, one at a time, using \(model). Nothing from a run is stored; only when it ended and whether it succeeded.")
        }
    }

    @ViewBuilder
    private var contextRows: some View {
        if selectedChoice == nil {
            Text("Choose a model in the toolbar to measure the prompt.")
                .foregroundStyle(.secondary)
                .groupedRow()
        } else {
            switch measure {
            case .idle, .measuring:
                LabeledContent("Prompt and tools") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring…")
                            .foregroundStyle(.secondary)
                    }
                }
                .groupedRow()
            case .measured(let measurement):
                LabeledContent("Prompt and tools") {
                    HStack(spacing: 8) {
                        Text(ContextGauge.text(used: measurement.fixedTokens, window: measurement.window, percent: true))
                            .monospacedDigit()
                            .foregroundStyle(ContextGauge.tint(used: measurement.fixedTokens, of: measurement.window, base: .primary))
                        Button {
                            Task { await measureContext() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Measure again")
                    }
                }
                .groupedRow()
                if let choice = selectedChoice, case .openAICompatible = choice, measurement.windowSource == nil || settings.contextWindows[choice.rawValue] != nil {
                    Divider().padding(.leading, 12)
                    LabeledContent("Window size to assume") {
                        TextField("tokens", value: windowOverride(for: choice.rawValue), format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    .groupedRow()
                }
            case .failed(let message):
                LabeledContent("Prompt and tools") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await measureContext() } }
                            .controlSize(.small)
                    }
                }
                .groupedRow()
            }
        }
    }

    @ViewBuilder
    private var contextFootnote: some View {
        if case .measured(let measurement) = measure, let choice = selectedChoice {
            let parts = "the system prompt and \(measurement.toolCount.counted("tool definition"))"
            if let source = measurement.windowSource {
                Text("Fixed cost of \(parts), counted by the model's tokenizer. Window size reported by \(source).")
            } else if choice.isApple {
                Text("Fixed cost of \(parts), counted by the framework's tokenizer. The framework does not report a window size.")
            } else {
                Text("Fixed cost of \(parts), counted by the server. It did not report a window size; enter the size the model runs with so AITaskRunner can warn you and trim older tool results.")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Model", selection: modelSelection) {
                ModelPickerOptions(
                    choices: providers.choices,
                    unavailable: selectedModel,
                    noneTitle: selectedModel.isEmpty && !providers.choices.isEmpty ? "Choose a model" : nil,
                    requirements: task.effectiveRequirements
                )
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 300)
            .help("Model used when running this task")

            RunOptionsButton(options: runOptions, choice: selectedChoice)

            Button(action: run) {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(!canRun)
            .keyboardShortcut("r", modifiers: .command)
            .help(runHelp)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Edit Task…") { store.beginEditing(id: task.id) }
                Button("Duplicate Task") { store.duplicate(id: task.id) }
                Divider()
                Button("Export Task…") { TaskExporter.save(task, registry: registry) }
                Button("Copy Task as JSON") { TaskExporter.copyToPasteboard(task, registry: registry) }
                Divider()
                Button("Delete Task…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    /// `key` is the model's `ModelChoice.rawValue`.
    private func windowOverride(for key: String) -> Binding<Int?> {
        Binding(
            get: { settings.contextWindows[key] },
            set: { value in
                if let value, value > 0 {
                    settings.contextWindows[key] = value
                } else {
                    settings.contextWindows[key] = nil
                }
            }
        )
    }

    private func measureContext() async {
        guard let choice = selectedChoice else {
            measure = .idle
            return
        }
        measure = .measuring
        do {
            let result = try await ContextProbe.measure(task: task, model: choice, registry: registry, providers: providers)
            guard !Task.isCancelled else { return }
            measure = .measured(result)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            measure = .failed(error.localizedDescription)
        }
    }

    /// Prefers the remembered default, then the first model not known to lack something the task needs.
    private func pickDefaultModelIfNeeded() {
        guard selectedChoice == nil, !providers.choices.isEmpty else { return }
        let requirements = task.effectiveRequirements
        let usable = providers.choices.filter { providers.knownCapabilities(for: $0).satisfies(requirements) }
        if let remembered = ModelChoice(rawValue: settings.defaultModel), usable.contains(remembered) {
            modelSelection.wrappedValue = remembered.rawValue
        } else if selectedModel.isEmpty {
            modelSelection.wrappedValue = (usable.first ?? providers.choices[0]).rawValue
        }
    }

    private func run() {
        if task.variables.contains(where: { !$0.key.isEmpty }) {
            showRunSheet = true
        } else {
            launch(values: [:])
        }
    }

    /// Remembers the entered values on the task (lists are saved as the list itself), then opens the run window.
    private func launch(values: [String: String], lists: [String: [String]] = [:]) {
        if !values.isEmpty, var stored = store.task(id: task.id) {
            stored.setListOptions(lists)
            stored.variableValues = values.filter { lists[$0.key] == nil }
            store.update(stored)
        }
        store.flush()
        settings.defaultModel = selectedModel
        openWindow(id: "run", value: RunRequest(runID: UUID(), taskID: task.id, model: selectedModel, variableValues: values))
    }
}
