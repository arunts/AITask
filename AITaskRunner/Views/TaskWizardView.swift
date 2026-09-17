import AppKit
import SwiftUI

/// Wizard used both to create and to edit a task.
/// Step 1: system prompt + user prompt, with the tools and variables they reference.
/// Step 2: name, interactive steering and, for tasks without steering, an optional schedule.
struct TaskWizardView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case composer
        case details

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .composer: return "Prompts & Tools"
            case .details: return "Name & Schedule"
            }
        }
    }

    let draft: TaskDraft

    @Environment(TaskStore.self) private var store
    @Environment(ProviderHub.self) private var providers
    @State private var task: AgentTask
    @State private var step: Step = .composer
    @State private var confirmDiscard = false

    init(draft: TaskDraft) {
        self.draft = draft
        _task = State(initialValue: draft.task)
    }

    private var hasChanges: Bool { task != draft.task }

    private var duplicateKeys: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for key in task.variables.map(\.key) where !key.isEmpty {
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        return duplicates
    }

    private var hasName: Bool {
        !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What still blocks leaving the prompt step.
    private var composerProblem: String? {
        if task.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a user prompt to save this task"
        }
        if !duplicateKeys.isEmpty {
            return "Two variables share the key \(duplicateKeys.sorted()[0])"
        }
        return nil
    }

    /// What still blocks saving from the details step.
    private var detailsProblem: String? {
        if !hasName { return "Give the task a name" }
        guard task.canBeScheduled, task.schedule != nil else { return nil }
        guard let raw = task.preferredModel, let choice = ModelChoice(rawValue: raw) else {
            return "Choose a model for the schedule"
        }
        let missing = providers.knownCapabilities(for: choice).unsupported(among: task.effectiveRequirements)
        if !missing.isEmpty {
            return "\(choice.displayName) does not support \(missing.listed)"
        }
        return nil
    }

    private var saveProblem: String? { composerProblem ?? detailsProblem }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .composer:
                    ComposerStep(task: $task, duplicateKeys: duplicateKeys)
                case .details:
                    DetailsStep(task: $task) { save() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 980, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        .navigationTitle(draft.isNew ? "New Task" : "Edit “\(draft.task.displayName)”")
        .background(WindowCloseInterceptor { cancel() })
        .confirmationDialog("Discard changes to this task?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { store.cancelDraft() }
        } message: {
            Text(draft.isNew ? "The new task will not be saved." : "Your edits will be lost.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            StepIndicator(current: step)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch step {
            case .composer:
                Button("Next") { step = .details }
                    .buttonStyle(.borderedProminent)
                    .disabled(composerProblem != nil)
                    .help(composerProblem ?? "Continue to the name and schedule")
            case .details:
                Button("Back") { step = .composer }
                saveButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var saveButton: some View {
        Button(draft.isNew ? "Create Task" : "Save Changes") { save() }
            .buttonStyle(.borderedProminent)
            .disabled(saveProblem != nil)
            .keyboardShortcut("s", modifiers: .command)
            .help(saveProblem ?? "Save (⌘S)")
    }

    private func cancel() {
        if hasChanges {
            confirmDiscard = true
        } else {
            store.cancelDraft()
        }
    }

    private func save() {
        guard saveProblem == nil else { return }
        var saved = task
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.variables.removeAll { $0.key.isEmpty }
        if !saved.canBeScheduled { saved.schedule = nil }
        if !saved.canHaveTimeLimit { saved.runTimeoutSeconds = nil }
        // A run while the editor was open may have remembered new values or added list entries; keep them.
        if let current = store.task(id: saved.id) {
            saved.variableValues = current.variableValues
            saved.runTimeoutSeconds = current.runTimeoutSeconds
            for index in saved.variables.indices where saved.variables[index].kind == .list {
                let id = saved.variables[index].id
                guard let stored = current.variables.first(where: { $0.id == id }) else { continue }
                let original = draft.task.variables.first(where: { $0.id == id })?.options ?? []
                saved.variables[index].addOptions(stored.options.filter { !original.contains($0) })
            }
        }
        // The scheduler may have run the task while it was being edited; keep that history.
        if var schedule = saved.schedule, let current = store.task(id: saved.id)?.schedule {
            schedule.lastRunAt = current.lastRunAt
            schedule.lastOutcome = current.lastOutcome
            saved.schedule = schedule
        }
        store.commitDraft(saved)
    }
}

// MARK: - Step indicator

/// Shows where you are; Back and Next do the moving.
private struct StepIndicator: View {
    let current: TaskWizardView.Step
    private let steps = TaskWizardView.Step.allCases

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 5) {
                    Image(systemName: step.rawValue < current.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle.fill")
                        .foregroundStyle(step.rawValue <= current.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(step.title)
                        .foregroundStyle(step == current ? .primary : .secondary)
                        .fontWeight(step == current ? .semibold : .regular)
                }
                if step != steps.last {
                    Image(systemName: "chevron.right")
                        .textStyle(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .textStyle(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(steps.count): \(current.title)")
    }
}

// MARK: - Step 1: system prompt + user prompt, with tools and variables

/// Which prompt editor takes the next inserted token: the one edited last.
private enum PromptTarget {
    case system
    case user
}

private struct ComposerStep: View {
    @Binding var task: AgentTask
    let duplicateKeys: Set<String>

    @Environment(MCPRegistry.self) private var registry
    @State private var systemInsertion: String?
    @State private var userInsertion: String?
    @State private var target: PromptTarget = .user
    @State private var showGuide = false
    /// Share of the prompt area given to the system prompt.
    @State private var split: CGFloat = 1 / 3
    @State private var dragStartHeight: CGFloat?

    private static let handleHeight: CGFloat = 16
    private static let minSystemHeight: CGFloat = 96
    private static let minUserHeight: CGFloat = 180

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                // The system prompt gets a third of the height and the user prompt the rest, until the
                // divider between them is dragged. (VSplitView ignores ideal heights and halves the space.)
                GeometryReader { geometry in
                    let total = max(geometry.size.height - Self.handleHeight, Self.minSystemHeight + Self.minUserHeight)
                    let systemHeight = min(max(total * split, Self.minSystemHeight), total - Self.minUserHeight)
                    VStack(spacing: 0) {
                        systemPane
                            .frame(height: systemHeight)
                        splitHandle(total: total, systemHeight: systemHeight)
                        userPane
                            .frame(maxHeight: .infinity)
                    }
                }
                Text("Drag a tool or variable in from the panel, or click one to insert it into the prompt you edited last. Blue names are tools the model may call, purple ones are variables filled in before each run. Typing them works too: server__tool and {{key}}.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

            ComposerSidePanel(task: $task, duplicateKeys: duplicateKeys) { token in
                switch target {
                case .system: systemInsertion = token
                case .user: userInsertion = token
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)
        }
    }

    private var systemPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("System prompt")
                    .textStyle(.headline)
                Text("Optional")
                    .textStyle(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Examples…") { showGuide.toggle() }
                    .controlSize(.small)
                    .popover(isPresented: $showGuide) {
                        SystemPromptGuide()
                    }
            }
            editor(
                text: $task.systemPrompt,
                insertion: $systemInsertion,
                placeholder: "Who the model is, its rules and the shape of its answers. Sent before every run of this task.",
                target: .system
            )
        }
    }

    private var userPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("User prompt")
                    .textStyle(.headline)
                Text("Required")
                    .textStyle(.callout)
                    .foregroundStyle(.tertiary)
            }
            editor(
                text: $task.userPrompt,
                insertion: $userInsertion,
                placeholder: "The job to do on each run, step by step.",
                target: .user
            )
        }
        .padding(.top, 10)
    }

    /// Draggable divider between the two prompts.
    private func splitHandle(total: CGFloat, systemHeight: CGFloat) -> some View {
        Divider()
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? systemHeight
                        dragStartHeight = start
                        let wanted = start + value.translation.height
                        let clamped = min(max(wanted, Self.minSystemHeight), total - Self.minUserHeight)
                        split = clamped / total
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityLabel("Resize prompts")
    }

    private func editor(text: Binding<String>, insertion: Binding<String?>, placeholder: String, target: PromptTarget) -> some View {
        PromptTextView(
            text: text,
            insertion: insertion,
            placeholder: placeholder,
            highlightPrefixes: registry.highlightPrefixes(for: task),
            highlightNames: registry.highlightNames(for: task),
            highlightVariables: task.variableKeys,
            onFocus: { self.target = target }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// Popover explaining what belongs in a system prompt, with examples.
private struct SystemPromptGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writing a system prompt")
                .textStyle(.headline)
            Text("Think of it as the model's job description. It is sent before every user prompt of this task, so keep it general and put the specific job in the next step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            guideRow(
                symbol: "person.crop.circle",
                title: "Persona",
                text: "Who the model is, its expertise and tone.",
                example: "You are a senior Swift reviewer who writes tersely and never flatters."
            )
            guideRow(
                symbol: "exclamationmark.shield",
                title: "Binding rules",
                text: "Commands it must always obey, phrased as Always / Never / Only.",
                example: "Never modify files outside /tmp. Always cite the file path. Ask with ask_user before guessing."
            )
            guideRow(
                symbol: "doc.text",
                title: "Output format",
                text: "The shape of every answer.",
                example: "Reply in Markdown. Start with a one-line summary, then bullet points."
            )
            guideRow(
                symbol: "wrench.and.screwdriver",
                title: "Tool habits",
                text: "How it should use the attached tools; server__tool names work here too.",
                example: "Call filesystem__read_file before summarising; never guess file contents."
            )
        }
        .padding(20)
        .frame(width: 440)
    }

    private func guideRow(symbol: String, title: String, text: String, example: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .textStyle(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textStyle(.subheadline, weight: .semibold)
                Text(text).textStyle(.callout).foregroundStyle(.secondary)
                Text("“\(example)”")
                    .textStyle(.callout, design: .monospaced)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

// MARK: - Step 2: name, steering and schedule

private struct DetailsStep: View {
    @Binding var task: AgentTask
    let onSubmit: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $task.name)
                    .labelsHidden()
                    .textStyle(.title3)
                    .controlSize(.large)
                    .focused($nameFocused)
                    .onSubmit(onSubmit)
            }
            Section {
                Toggle("Interactive steering", isOn: $task.allowsSteering)
            } header: {
                Text("Interaction")
            } footer: {
                Text("Adds a chat box to the run window and an ask_user tool so the model can pause and ask you questions. Interactive tasks cannot run on a schedule.")
                    .textStyle(.callout)
            }
            ScheduleSections(task: $task)
        }
        .formStyle(.grouped)
        .defaultFocus($nameFocused, true)
        .task {
            // The default focus can miss when the step appears; ask again once it is on screen.
            try? await Task.sleep(for: .milliseconds(120))
            nameFocused = true
        }
    }
}

/// Schedule sections of the details step. Greyed out while steering is on, since an interactive task
/// cannot run unattended; `save()` drops any schedule such a task still carries.
private struct ScheduleSections: View {
    @Binding var task: AgentTask

    @Environment(ProviderHub.self) private var providers

    private var isScheduled: Bool { task.canBeScheduled && task.schedule != nil }

    private var enabled: Binding<Bool> {
        Binding(
            get: { isScheduled },
            set: { on in task.schedule = on ? (task.schedule ?? TaskSchedule()) : nil }
        )
    }

    private var hours: Binding<Int> {
        Binding(
            get: { task.schedule?.intervalHours ?? 6 },
            set: { value in
                let range = TaskSchedule.intervalRange
                task.schedule?.intervalHours = min(max(value, range.lowerBound), range.upperBound)
                task.schedule?.startedAt = .now
            }
        )
    }

    private var model: Binding<String> {
        Binding(
            get: { task.preferredModel ?? "" },
            set: { task.preferredModel = $0.isEmpty ? nil : $0 }
        )
    }

    private var usesShell: Bool {
        task.toolAttachments.contains { BuiltinToolPack(id: $0.serverID) == .shell }
    }

    var body: some View {
        Section {
            Toggle("Run on a schedule", isOn: enabled)
                .disabled(!task.canBeScheduled)
        } header: {
            Text("Schedule")
        } footer: {
            if task.canBeScheduled {
                Text("Repeats the task unattended while AITaskRunner is open. Runs happen one at a time, and nothing from a run is kept except when it ended and whether it succeeded.")
                    .textStyle(.callout)
            } else {
                Label("Not available while interactive steering is on: an unattended run has nobody to answer the model's questions. Turn steering off to schedule this task.", systemImage: "info.circle")
                    .textStyle(.callout)
            }
        }
        if isScheduled {
            Section {
                LabeledContent("Every") {
                    Stepper(value: hours, in: TaskSchedule.intervalRange) {
                        HStack(spacing: 4) {
                            TextField("Hours", value: hours, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Text(hours.wrappedValue == 1 ? "hour" : "hours")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Model", selection: model) {
                    ModelPickerOptions(
                        choices: providers.choices, unavailable: task.preferredModel, noneTitle: "Choose a model",
                        requirements: task.effectiveRequirements
                    )
                }
            } header: {
                Text("How often, and with which model")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The first run is one interval after you save; later runs follow one interval after the previous run ends. A run starts only while this model is available and supports what the task needs, otherwise it waits. Variables use the values from the last run, or their defaults.")
                    if usesShell {
                        Label("This task can run shell commands. In a scheduled run they run without asking for your approval.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .textStyle(.callout)
            }
        }
    }
}

// MARK: - Right panel of the composer: tools + variables

private struct ComposerSidePanel: View {
    @Binding var task: AgentTask
    let duplicateKeys: Set<String>
    let onInsert: (String) -> Void

    @Environment(MCPRegistry.self) private var registry
    @State private var showPicker = false
    @State private var pickerExpands: UUID?
    @FocusState private var focusedVariable: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                toolsSection
                variablesSection
                requirementsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tools")
                    .textStyle(.headline)
                Spacer()
                Button {
                    pickerExpands = nil
                    showPicker = true
                } label: {
                    Label("Add Tools", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Choose servers and the tools the model may call")
                .popover(isPresented: $showPicker) {
                    ToolPickerPanel(attachments: $task.toolAttachments, initiallyExpanded: pickerExpands)
                }
            }
            if task.toolAttachments.isEmpty {
                Text("None attached. Click + to choose servers and tools; they appear here, ready to drag into the prompt.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(task.toolAttachments) { attachment in
                    AttachedServerSection(attachment: attachment, onInsert: onInsert) {
                        task.toolAttachments.removeAll { $0.serverID == attachment.serverID }
                    } onEdit: {
                        pickerExpands = attachment.serverID
                        showPicker = true
                    }
                }
            }
        }
    }

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Variables")
                    .textStyle(.headline)
                Spacer()
                Button {
                    addVariable()
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Add a value you fill in before each run, referenced in the prompts as {{key}}")
            }
            if task.variables.isEmpty {
                Text("None yet. A variable is a value you fill in before each run, such as an input folder. Reference it in a prompt as {{key}}.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($task.variables) { $variable in
                    VariableEditorRow(
                        variable: $variable,
                        isDuplicate: duplicateKeys.contains(variable.key),
                        focus: $focusedVariable,
                        onInsert: onInsert
                    ) {
                        task.variables.removeAll { $0.id == variable.id }
                    }
                }
            }
        }
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model requirements")
                .textStyle(.headline)
            Text("What the model must support. Models known to lack any of it are marked in the picker and never run this task.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ModelCapability.allCases) { capability in
                RequirementToggle(task: $task, capability: capability)
            }
        }
    }

    private func addVariable() {
        var key = "variable"
        var counter = 2
        while task.variables.contains(where: { $0.key == key }) {
            key = "variable_\(counter)"
            counter += 1
        }
        let variable = TaskVariable(key: key)
        task.variables.append(variable)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            focusedVariable = variable.id
        }
    }
}

/// One capability the task may demand. Tool calling is ticked and locked while the task attaches tools
/// or is interactive, because both need it whether or not the task says so.
private struct RequirementToggle: View {
    @Binding var task: AgentTask
    let capability: ModelCapability

    private var isImplied: Bool { task.impliedCapabilities.contains(capability) }

    private var isOn: Binding<Bool> {
        Binding(
            get: { isImplied || task.requiredCapabilities.contains(capability) },
            set: { on in
                if on {
                    task.requiredCapabilities.insert(capability)
                } else {
                    task.requiredCapabilities.remove(capability)
                }
            }
        )
    }

    private var hint: String {
        guard isImplied else { return capability.explanation }
        return task.usesTools ? "Needed for the attached tools." : "Needed for the ask_user tool of an interactive task."
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Label(capability.label, systemImage: capability.symbol)
                Text(hint)
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isImplied)
        .help(isImplied ? "Always on while the task uses tools" : capability.explanation)
    }
}

/// Editable variable: key, type, default and hint, with the draggable `{{key}}` chip as the box label.
private struct VariableEditorRow: View {
    @Binding var variable: TaskVariable
    let isDuplicate: Bool
    let focus: FocusState<UUID?>.Binding
    let onInsert: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Key", text: $variable.key, prompt: Text("key"))
                        .labelsHidden()
                        .textStyle(.body, design: .monospaced)
                        .focused(focus, equals: variable.id)
                        .onChange(of: variable.key) {
                            let clean = TaskVariable.sanitizeKey(variable.key)
                            if clean != variable.key { variable.key = clean }
                        }
                    Picker("Type", selection: $variable.kind) {
                        ForEach(TaskVariable.Kind.allCases) { kind in
                            Image(systemName: kind.symbol)
                                .tag(kind)
                                .help(kind.label)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Type: \(variable.kind.label). File and Folder show a picker when you run the task; List shows a menu of values.")
                    .onChange(of: variable.kind) { _, kind in
                        // Switching to List keeps a typed default by making it the first entry.
                        if kind == .list, variable.options.isEmpty, !variable.defaultValue.isEmpty {
                            variable.addOptions([variable.defaultValue])
                        }
                        if kind == .list { variable.defaultValue = "" }
                    }
                }
                if variable.kind == .list {
                    ListOptionsEditor(variable: $variable)
                } else {
                    HStack(spacing: 8) {
                        TextField("Default", text: $variable.defaultValue, prompt: Text(variable.kind.isPath ? "Default path" : "Default value"))
                            .labelsHidden()
                        if variable.kind.isPath {
                            Button("Choose…") { chooseDefaultPath() }
                        }
                    }
                }
                TextField("Hint", text: $variable.description, prompt: Text("Hint shown when running (optional)"))
                    .labelsHidden()
                if isDuplicate {
                    Label("Another variable uses this key.", systemImage: "exclamationmark.triangle")
                        .textStyle(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                if variable.key.isEmpty {
                    Text("{{ }}")
                        .textStyle(.callout, design: .monospaced)
                        .foregroundStyle(.tertiary)
                } else {
                    TokenChip(token: variable.placeholder, description: variable.description, color: .purple, onInsert: onInsert)
                }
                Spacer(minLength: 0)
                Button(action: onRemove) {
                    Label("Remove Variable", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this variable")
            }
        }
    }

    private func chooseDefaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = variable.kind == .folder
        panel.canChooseFiles = variable.kind == .file
        panel.allowsMultipleSelection = false
        panel.message = "Choose the default \(variable.kind == .folder ? "folder" : "file") for \(variable.placeholder)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        variable.defaultValue = url.path
    }
}

/// The entries of a list variable, one field each. The list as saved here is what a run starts from.
private struct ListOptionsEditor: View {
    @Binding var variable: TaskVariable

    @FocusState private var focusedIndex: Int?

    private var isFull: Bool { variable.options.count >= TaskVariable.maxOptions }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Values")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(variable.options.count) of \(TaskVariable.maxOptions)")
                    .textStyle(.callout)
                    .foregroundStyle(isFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
                Button {
                    addOption()
                } label: {
                    Label("Add Value", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isFull)
                .help(isFull ? "A list holds at most \(TaskVariable.maxOptions) values" : "Add a value")
            }
            if variable.options.isEmpty {
                Text("No values yet. All values go into the prompt; more can be added when running.")
                    .textStyle(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(variable.options.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("Value", text: optionBinding(index), prompt: Text("Value"))
                        .labelsHidden()
                        .focused($focusedIndex, equals: index)
                        .onSubmit { commitOption(at: index, thenAdd: true) }
                    Button {
                        removeOption(at: index)
                    } label: {
                        Label("Remove Value", systemImage: "minus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this value")
                }
            }
        }
        .onChange(of: focusedIndex) { previous, _ in
            if let previous { commitOption(at: previous, thenAdd: false) }
        }
    }

    /// Edits keep the raw text while typing; trimming and de-duplication happen when the field loses focus.
    private func optionBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < variable.options.count ? variable.options[index] : "" },
            set: { newValue in
                guard index < variable.options.count else { return }
                variable.options[index] = newValue
            }
        )
    }

    private func addOption() {
        guard !isFull else { return }
        variable.options.append("")
        let index = variable.options.count - 1
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            focusedIndex = index
        }
    }

    /// Trims the value; drops it if blank or a repeat of an earlier one.
    private func commitOption(at index: Int, thenAdd: Bool) {
        guard index < variable.options.count else { return }
        let trimmed = variable.options[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let repeated = variable.options[..<index].contains(trimmed)
        if trimmed.isEmpty || repeated {
            variable.options.remove(at: index)
            if focusedIndex == index { focusedIndex = nil }
        } else if trimmed != variable.options[index] {
            variable.options[index] = trimmed
        }
        if thenAdd { addOption() }
    }

    private func removeOption(at index: Int) {
        guard index < variable.options.count else { return }
        focusedIndex = nil
        variable.options.remove(at: index)
    }
}

private struct AttachedServerSection: View {
    let attachment: ToolAttachment
    let onInsert: (String) -> Void
    let onRemove: () -> Void
    let onEdit: () -> Void

    @Environment(MCPRegistry.self) private var registry

    private var server: MCPServerConfig? { registry.server(id: attachment.serverID) }

    var body: some View {
        if let server {
            let state = registry.state(for: server.id)
            let liveTools = registry.tools(for: server.id)
            let names = attachment.toolNames ?? liveTools.map(\.name)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusIcon(tone: state.tone)
                        .textStyle(.callout)
                    Text(server.name)
                        .textStyle(.callout, weight: .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(attachment.includesAllTools ? "all tools" : names.count.counted("tool"))
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                    Button(action: onEdit) {
                        Label("Choose Tools", systemImage: "checklist")
                    }
                    .help("Change which of \(server.name)'s tools are attached")
                    Button(action: onRemove) {
                        Label("Detach", systemImage: "xmark.circle.fill")
                    }
                    .help("Detach \(server.name)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                if names.isEmpty {
                    HStack(spacing: 8) {
                        Text(state == .connected ? "This server exposes no tools." : "Connect to list its tools.")
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                        if state != .connected, state != .connecting {
                            Button("Connect") { Task { await registry.connect(id: server.id) } }
                                .controlSize(.mini)
                        } else if state == .connecting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } else {
                    ForEach(names, id: \.self) { name in
                        TokenChip(
                            token: "\(server.slug)__\(name)",
                            description: liveTools.first { $0.name == name }?.description,
                            color: .accentColor,
                            onInsert: onInsert
                        )
                    }
                }
            }
        } else {
            HStack {
                Label("Attached server no longer exists", systemImage: "exclamationmark.triangle")
                    .textStyle(.callout)
                    .foregroundStyle(.red)
                Spacer()
                Button("Remove", action: onRemove).controlSize(.mini)
            }
        }
    }
}

/// One insertable token (`server__tool` or `{{key}}`): click to insert at the cursor, or drag into the prompt.
private struct TokenChip: View {
    let token: String
    let description: String?
    let color: Color
    let onInsert: (String) -> Void

    @State private var hovering = false

    var body: some View {
        Text(token)
            .textStyle(.callout, design: .monospaced)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(hovering ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { onInsert(token) }
            .draggable(token)
            .help(description?.isEmpty == false ? description! : token)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Inserts \(token) into the prompt")
    }
}

// MARK: - Picker (the + panel)

private struct ToolPickerPanel: View {
    @Binding var attachments: [ToolAttachment]
    var initiallyExpanded: UUID?

    @Environment(MCPRegistry.self) private var registry
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<UUID> = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var visibleServers: [MCPServerConfig] {
        guard !trimmedQuery.isEmpty else { return registry.servers }
        return registry.servers.filter { server in
            server.name.lowercased().contains(trimmedQuery)
                || server.slug.contains(trimmedQuery)
                || registry.tools(for: server.id).contains { $0.name.lowercased().contains(trimmedQuery) }
        }
    }

    private var summary: String {
        guard !attachments.isEmpty else { return "Nothing attached yet" }
        let explicit = attachments.compactMap(\.toolNames).map(\.count).reduce(0, +)
        let allCount = attachments.filter(\.includesAllTools).count
        var parts: [String] = []
        if allCount > 0 { parts.append("\(allCount.counted("server")) with all tools") }
        if explicit > 0 { parts.append("\(explicit.counted("selected tool"))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Tools")
                    .textStyle(.headline)
                Text("Tick a server to attach every tool it offers, or expand it and pick specific tools.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Filter", text: $query, prompt: Text("Filter servers and tools"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if registry.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Tools Available", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("Turn on the built-in tools or add an MCP server in Settings.")
                } actions: {
                    Button("Open Settings…") { openSettings() }
                }
            } else {
                List {
                    ForEach(visibleServers) { server in
                        ServerPickerRow(
                            server: server,
                            attachments: $attachments,
                            query: trimmedQuery,
                            expanded: Binding(
                                get: { expanded.contains(server.id) || !trimmedQuery.isEmpty },
                                set: { if $0 { expanded.insert(server.id) } else { expanded.remove(server.id) } }
                            )
                        )
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text(summary)
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 460, height: 540)
        .onAppear {
            if let initiallyExpanded { expanded.insert(initiallyExpanded) }
        }
    }
}

private struct ServerPickerRow: View {
    let server: MCPServerConfig
    @Binding var attachments: [ToolAttachment]
    let query: String
    @Binding var expanded: Bool

    @Environment(MCPRegistry.self) private var registry

    private enum Check { case none, partial, all }

    private var attachment: ToolAttachment? { attachments.first { $0.serverID == server.id } }
    private var tools: [MCPTool] { registry.tools(for: server.id) }
    private var state: MCPRegistry.State { registry.state(for: server.id) }

    private var visibleTools: [MCPTool] {
        guard !query.isEmpty, !server.name.lowercased().contains(query), !server.slug.contains(query) else { return tools }
        return tools.filter { $0.name.lowercased().contains(query) }
    }

    private var check: Check {
        guard let attachment else { return .none }
        guard let names = attachment.toolNames else { return .all }
        if names.isEmpty { return .none }
        if !tools.isEmpty, Set(names).isSuperset(of: tools.map(\.name)) { return .all }
        return .partial
    }

    private var checkSymbol: String {
        switch check {
        case .none: return "square"
        case .partial: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private var statusText: String {
        switch state {
        case .connected: return tools.count.counted("tool")
        default: return state.label
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if tools.isEmpty {
                Text(state == .connected ? "This server exposes no tools." : "Connect to list this server's tools.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleTools) { tool in
                    Toggle(isOn: binding(for: tool)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(server.slug)__\(tool.name)")
                                .textStyle(.callout, design: .monospaced)
                            if let description = tool.description, !description.isEmpty {
                                Text(description)
                                    .textStyle(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Button(action: toggleServer) {
                    Image(systemName: checkSymbol)
                        .textStyle(.title3)
                        .foregroundStyle(check == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .help(check == .none ? "Attach all of \(server.name)'s tools" : "Detach \(server.name)")
                .accessibilityLabel(server.name)
                .accessibilityValue(check == .all ? "all tools" : check == .partial ? "some tools" : "not attached")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(server.name).textStyle(.callout, weight: .medium)
                        Text("\(server.slug)__")
                            .textStyle(.callout, design: .monospaced)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        StatusIcon(tone: state.tone)
                            .textStyle(.subheadline)
                        Text(statusText)
                            .textStyle(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if state == .connecting {
                    ProgressView().controlSize(.small)
                } else if state != .connected {
                    Button("Connect") { Task { await registry.connect(id: server.id) } }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
        .onChange(of: expanded) {
            if expanded, state != .connected, state != .connecting {
                Task { await registry.connect(id: server.id) }
            }
        }
    }

    private func toggleServer() {
        if check == .none {
            attachments.removeAll { $0.serverID == server.id }
            attachments.append(ToolAttachment(serverID: server.id))
            if state != .connected, state != .connecting {
                Task { await registry.connect(id: server.id) }
            }
        } else {
            attachments.removeAll { $0.serverID == server.id }
        }
    }

    private func binding(for tool: MCPTool) -> Binding<Bool> {
        Binding(
            get: { attachment?.includes(tool.name) ?? false },
            set: { on in
                let allNames = tools.map(\.name)
                guard let index = attachments.firstIndex(where: { $0.serverID == server.id }) else {
                    if on { attachments.append(ToolAttachment(serverID: server.id, toolNames: [tool.name])) }
                    return
                }
                var current = attachments[index]
                var names = current.toolNames ?? allNames
                if on {
                    if !names.contains(tool.name) { names.append(tool.name) }
                } else {
                    names.removeAll { $0 == tool.name }
                }
                if names.isEmpty {
                    attachments.remove(at: index)
                } else {
                    current.toolNames = Set(names).isSuperset(of: allNames) ? nil : names
                    attachments[index] = current
                }
            }
        )
    }
}
