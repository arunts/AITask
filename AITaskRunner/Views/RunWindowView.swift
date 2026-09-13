import SwiftUI

/// Root of a run window. Builds the runner from the request and tears it down when the window closes.
struct RunWindowView: View {
    let request: RunRequest

    @Environment(TaskStore.self) private var store
    @Environment(MCPRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderHub.self) private var providers
    @Environment(TaskScheduler.self) private var scheduler

    @State private var runner: TaskRunner?
    @State private var missing = false
    /// Whether this window is counted as an active run, so scheduled runs wait for it.
    @State private var countedAsActive = false

    var body: some View {
        Group {
            if let runner {
                RunTranscriptView(runner: runner)
                    .focusedSceneValue(\.taskRunner, runner)
            } else if missing {
                ContentUnavailableView("Task Not Found", systemImage: "questionmark.folder")
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            guard runner == nil else { return }
            guard let task = store.task(id: request.taskID), let choice = ModelChoice(rawValue: request.model) else {
                missing = true
                return
            }
            let newRunner = TaskRunner(task: task, model: choice, registry: registry, settings: settings, providers: providers, variableValues: request.variableValues)
            runner = newRunner
            newRunner.start()
            scheduler.manualRunStarted()
            countedAsActive = true
        }
        .onChange(of: runner?.isActive) { _, active in
            if active == false { runEnded() }
        }
        .onDisappear {
            runner?.stop()
            runEnded()
        }
    }

    /// Releases the scheduler and, for a scheduled task, notes when this manual run ended.
    private func runEnded() {
        guard countedAsActive else { return }
        countedAsActive = false
        scheduler.manualRunEnded()
        guard let runner, runner.task.schedule != nil else { return }
        let outcome: TaskSchedule.Outcome
        switch runner.status {
        case .failed(let reason): outcome = .failed(reason)
        case .stopped: outcome = .stopped
        default: outcome = .succeeded
        }
        store.recordRun(id: runner.task.id, outcome: outcome)
    }
}

struct RunTranscriptView: View {
    let runner: TaskRunner

    @State private var input = ""
    @State private var showThinking = false
    @State private var showToolCalls = false
    @FocusState private var inputFocused: Bool

    private var showsInput: Bool {
        runner.task.allowsSteering || runner.status == .waitingForInput
    }

    private var canSend: Bool {
        runner.canAcceptInput && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Blocks after applying the view filters. Assistant turns that would render empty are dropped too.
    private var visibleBlocks: [RunBlock] {
        runner.blocks.filter { block in
            switch block.role {
            case .tool:
                return showToolCalls
            case .approval:
                return true
            case .assistant:
                if block.isStreaming || !block.text.isEmpty { return true }
                return showThinking && !block.thinking.isEmpty
            default:
                return true
            }
        }
    }

    /// Changes whenever anything visible in the transcript grows, so the view can keep the end in sight.
    private var transcriptSignature: Int {
        runner.blocks.reduce(runner.blocks.count) { total, block in
            total &+ block.text.count &+ block.thinking.count &+ (block.toolResult?.count ?? 0) &+ block.toolImages.count
        }
    }

    private static let bottomAnchor = "transcript-bottom"

    var body: some View {
        let blocks = visibleBlocks
        VStack(spacing: 0) {
            statusBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks) { block in
                            RunBlockView(block: block, modelName: runner.modelName, showThinking: showThinking) { decision in
                                runner.resolveApproval(decision)
                            }
                            .padding(.vertical, 12)
                            if block.id != blocks.last?.id {
                                Divider()
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) {
                    if showsInput {
                        inputBar
                    }
                }
                .onChange(of: transcriptSignature) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onChange(of: showThinking) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                .onChange(of: showToolCalls) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .navigationTitle(runner.task.displayName)
        .navigationSubtitle(runner.modelTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if runner.isActive {
                    Button {
                        runner.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop the run (⌘.)")
                }
                Toggle(isOn: $showThinking) {
                    Label("Thinking", systemImage: "brain")
                }
                .help(showThinking ? "Hide the model's thinking" : "Show the model's thinking")
                Toggle(isOn: $showToolCalls) {
                    Label("Tool Calls", systemImage: "wrench.and.screwdriver")
                }
                .help(showToolCalls ? "Hide tool calls and results" : "Show tool calls and results")
            }
        }
        .onChange(of: runner.status) {
            if runner.status == .waitingForInput { inputFocused = true }
        }
    }

    /// Opaque bar under the toolbar: run status on the left, context readout on the right.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if let tone = runner.status.tone {
                Image(systemName: tone.symbol)
                    .foregroundStyle(tone.color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(runner.status.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(runner.status.label)
            Spacer()
            if let usage = runner.contextUsage {
                ContextUsageLabel(used: usage.used, window: usage.window, budget: usage.budget)
                    .textStyle(.callout)
                    .help(contextHelp(usage))
            }
        }
        .textStyle(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func contextHelp(_ usage: TaskRunner.ContextUsage) -> String {
        var lines = [ContextGauge.text(used: usage.used, window: usage.window)]
        lines.append(usage.isExact ? "Counted by the model's own tokenizer." : "Estimated.")
        if let source = usage.windowSource {
            lines.append("Window size reported by \(source).")
        } else if runner.model.isApple {
            lines.append("The framework does not report a window size; the colour uses Apple's documented limit.")
        } else {
            lines.append("Window size unknown. Set it in the task's Context section to get warnings.")
        }
        if !runner.toolNames.isEmpty {
            lines.append("\(runner.toolNames.count.counted("tool")): \(runner.toolNames.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(inputPlaceholder, text: $input, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(!runner.canAcceptInput)
                .padding(.vertical, 6)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⏎ or ⌘⏎). Option-⏎ adds a line.")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var inputPlaceholder: String {
        switch runner.status {
        case .waitingForInput: return "Answer the model…"
        case .preparing, .running: return "Steer the run; delivered after the current step…"
        default: return runner.canAcceptInput ? "Send a follow-up message…" : "Steering is not available for this run."
        }
    }

    private func send() {
        guard canSend else { return }
        runner.send(input)
        input = ""
    }
}

// MARK: - Blocks

/// One transcript entry. Plain rows with a small role label; only user turns and approvals get a background.
struct RunBlockView: View {
    let block: RunBlock
    let modelName: String
    var showThinking = true
    var onApproval: (TaskRunner.ApprovalDecision) -> Void = { _ in }

    @State private var systemExpanded = false
    @State private var thinkingExpanded = true
    @State private var toolExpanded = false
    @State private var showFullResult = false

    private static let resultPreviewLimit = 3_000

    var body: some View {
        switch block.role {
        case .system:
            DisclosureGroup(isExpanded: $systemExpanded) {
                Text(verbatim: block.text)
                    .textStyle(.callout, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                roleLabel("System prompt", symbol: "gearshape")
            }

        case .user:
            VStack(alignment: .leading, spacing: 6) {
                roleLabel("You", symbol: "person.fill")
                Text(verbatim: block.text)
                    .textSelection(.enabled)
                if let note = block.note {
                    Text(note)
                        .textStyle(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 12))

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    roleLabel(modelName, symbol: "sparkles")
                    if block.isStreaming { ProgressView().controlSize(.mini) }
                }
                if showThinking, !block.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $thinkingExpanded) {
                        Text(verbatim: block.thinking)
                            .textStyle(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    } label: {
                        roleLabel("Thinking", symbol: "brain")
                    }
                }
                if !block.text.isEmpty {
                    MarkdownView(text: block.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            DisclosureGroup(isExpanded: $toolExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !block.toolArguments.isEmpty, block.toolArguments != "{}" {
                        Text(verbatim: block.toolArguments)
                            .textStyle(.callout, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let result = block.toolResult {
                        Text(verbatim: showFullResult ? result : String(result.prefix(Self.resultPreviewLimit)))
                            .textStyle(.callout, design: .monospaced)
                            .foregroundStyle(block.toolIsError ? .red : .primary)
                            .textSelection(.enabled)
                        if result.count > Self.resultPreviewLimit, !showFullResult {
                            Button("Show all \(result.count.formatted()) characters") { showFullResult = true }
                                .controlSize(.small)
                        }
                    }
                    if !block.toolImages.isEmpty {
                        ToolImageStrip(images: block.toolImages)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text(block.toolName)
                        .textStyle(.callout, design: .monospaced)
                    if block.isStreaming {
                        ProgressView().controlSize(.mini)
                    } else if block.toolIsError {
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.red)
                    } else {
                        Label("Succeeded", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                    if let result = block.toolResult {
                        Text("\(result.count.formatted()) characters")
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !block.toolImages.isEmpty {
                        Text(block.toolImages.count.counted("image"))
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { if block.toolIsError { toolExpanded = true } }

        case .question:
            VStack(alignment: .leading, spacing: 6) {
                roleLabel("The model asks", symbol: "questionmark.bubble")
                    .foregroundStyle(.tint)
                MarkdownView(text: block.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approval:
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: block.text)
                        .textStyle(.callout, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let note = block.note {
                        Text(note)
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if block.approval == .pending {
                        HStack {
                            Button("Deny", role: .destructive) { onApproval(.deny) }
                            Spacer()
                            Button("Allow All This Run") { onApproval(.allowAll) }
                                .help("Run this and every later command in this run without asking")
                            Button("Allow") { onApproval(.allow) }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 2)
                    }
                }
            } label: {
                HStack {
                    Label(approvalTitle, systemImage: block.approval == .denied ? "hand.raised.slash.fill" : "hand.raised.fill")
                        .foregroundStyle(block.approval == .pending ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text(block.toolName)
                        .textStyle(.callout, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
            }

        case .notice:
            Text(block.text)
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

        case .error:
            Label(block.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var approvalTitle: String {
        switch block.approval {
        case .pending: return "Run this command?"
        case .allowed: return "Command approved"
        case .denied: return "Command denied"
        case nil: return "Approval"
        }
    }

    private func roleLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .textStyle(.callout, weight: .semibold)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Tool images

/// Thumbnails of the images a tool returned; clicking one opens it full size in a sheet.
struct ToolImageStrip: View {
    let images: [MCPImage]

    private struct Selection: Identifiable {
        let id: Int
    }

    @State private var selection: Selection?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images.indices, id: \.self) { index in
                    Button {
                        selection = Selection(id: index)
                    } label: {
                        ToolImageView(image: images[index])
                            .frame(maxWidth: 160, maxHeight: 120)
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("Image \(index + 1) of \(images.count) (\(images[index].mimeType))")
                }
            }
            .padding(.vertical, 2)
        }
        .sheet(item: $selection) { selected in
            ToolImageSheet(images: images, index: selected.id)
        }
    }
}

/// One decoded image. Decoding is done once, off the view body.
struct ToolImageView: View {
    let image: MCPImage
    @State private var decoded: NSImage?

    var body: some View {
        Group {
            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 80, height: 60)
            }
        }
        .task {
            if decoded == nil, let data = Data(base64Encoded: image.base64, options: .ignoreUnknownCharacters) {
                decoded = NSImage(data: data)
            }
        }
    }
}

/// Full-size view of one tool image, with arrows through the others from the same result.
struct ToolImageSheet: View {
    let images: [MCPImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Image \(index + 1) of \(images.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                if images.count > 1 {
                    Button("Previous", systemImage: "chevron.left") { index = max(0, index - 1) }
                        .disabled(index == 0)
                    Button("Next", systemImage: "chevron.right") { index = min(images.count - 1, index + 1) }
                        .disabled(index == images.count - 1)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .labelStyle(.iconOnly)
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ToolImageView(image: images[index])
                    .id(index)
                    .padding(12)
            }
        }
        .frame(minWidth: 480, idealWidth: 900, minHeight: 360, idealHeight: 700)
    }
}
