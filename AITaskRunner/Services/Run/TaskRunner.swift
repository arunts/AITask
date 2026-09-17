import Foundation
import Observation

/// A model backend that can process one user turn (including any tool-calling rounds).
protocol RunEngine: AnyObject {
    func runTurn(userInput: String) async throws
}

/// Why a run could not start, or go on, with the chosen model.
nonisolated enum CapabilityError: LocalizedError {
    /// The model is known to lack something the task requires.
    case unsupported(model: String, capabilities: [ModelCapability])
    /// The task requires vision and the server refused the images.
    case imagesRejected(model: String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let model, let capabilities):
            return "This task needs \(capabilities.listed), which \(model) does not support. Pick another model."
        case .imagesRejected(let model):
            return "This task needs vision, but \(model) rejected the images. Pick a vision model."
        }
    }
}

/// Coordinates one execution of a task: MCP connections, the model engine, the transcript and steering.
/// Lives only as long as its window; nothing here is persisted.
@Observable
final class TaskRunner {
    enum Status: Equatable {
        case preparing
        case running
        case waitingForInput
        case waitingForApproval
        case idle
        case finished
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .preparing: return "Preparing…"
            case .running: return "Running…"
            case .waitingForInput: return "Waiting for your answer"
            case .waitingForApproval: return "Waiting for your approval"
            case .idle: return "Done — send a message to continue"
            case .finished: return "Done"
            case .failed(let message): return "Failed: \(message)"
            case .stopped: return "Stopped"
            }
        }
    }

    let task: AgentTask
    let model: ModelChoice
    /// Model without its endpoint namespace, for role labels in the transcript.
    let modelName: String
    /// Model with its endpoint namespace, for the window subtitle.
    let modelTitle: String
    /// Effective variable values for this run.
    let variableValues: [String: String]
    /// A scheduled run with nobody watching: tools that would ask for approval run without it.
    let unattended: Bool
    /// Working-time budget in seconds, if any. Model and tool time count; waiting for an approval does not.
    /// Interactive tasks never have one.
    let timeoutSeconds: Int?

    /// How much of the model's context the conversation occupies, as last reported.
    struct ContextUsage: Equatable {
        var used: Int
        /// Reported window, when the provider tells us.
        var window: Int?
        var windowSource: String?
        /// Size used for the warning colour even when no window is reported (Apple's documented limit).
        var budget: Int?
        var isExact: Bool
    }

    private(set) var blocks: [RunBlock] = []
    private(set) var status: Status = .preparing {
        didSet { syncClock() }
    }
    private(set) var toolNames: [String] = []
    private(set) var contextUsage: ContextUsage?
    /// Progress the model last reported through `progress__update`, if the task attaches that tool.
    private(set) var progress: RunProgress?

    private let registry: MCPRegistry
    private let settings: AppSettings
    private let providers: ProviderHub
    private var contextWindow: (tokens: Int, source: String)?
    private var engine: (any RunEngine)?
    private var runTask: Task<Void, Never>?
    private var queuedInputs: [(block: RunBlock, text: String)] = []
    private var pendingAnswer: CheckedContinuation<String, Never>?

    /// Budget not yet spent while the clock was running.
    private var timeoutRemaining: Duration = .zero
    private var clockStartedAt: ContinuousClock.Instant?
    /// Sleeps for the remaining budget, then ends the run. Nil while the clock is paused.
    private var watchdog: Task<Void, Never>?
    /// Set once the budget ran out; the transcript and status already say so when cancellation lands.
    private(set) var timedOut = false

    enum ApprovalDecision {
        case allow
        case allowAll
        case deny
    }

    private(set) var approvedAllCommands = false
    private var pendingApproval: (block: RunBlock, continuation: CheckedContinuation<ApprovalDecision, Never>)?

    init(task: AgentTask, model: ModelChoice, registry: MCPRegistry, settings: AppSettings, providers: ProviderHub, variableValues: [String: String] = [:], unattended: Bool = false) {
        self.task = task
        self.model = model
        self.modelName = model.displayName
        self.modelTitle = settings.displayName(for: model)
        self.registry = registry
        self.settings = settings
        self.providers = providers
        self.variableValues = task.resolvedVariableValues(overrides: variableValues)
        self.unattended = unattended
        let timeoutSeconds = RunTimeout.effective(for: task, appDefault: settings.runTimeoutSeconds)
        self.timeoutSeconds = timeoutSeconds
        self.timeoutRemaining = .seconds(timeoutSeconds ?? 0)
    }

    /// Engines call this whenever the provider reports (or the framework counts) the prompt size.
    func reportContext(used: Int, isExact: Bool) {
        let budget: Int?
        switch model {
        case .appleFoundation: budget = FoundationEngine.documentedContextWindow
        case .openAICompatible: budget = contextWindow?.tokens
        }
        contextUsage = ContextUsage(used: used, window: contextWindow?.tokens, windowSource: contextWindow?.source, budget: budget, isExact: isExact)
    }

    /// The `progress__update` tool calls this with a validated value.
    func reportProgress(_ progress: RunProgress) {
        self.progress = progress
    }

    /// Text with this run's `{{variables}}` filled in.
    private func resolved(_ text: String) -> String {
        AgentTask.substitute(text, values: variableValues)
    }

    var isActive: Bool {
        switch status {
        case .preparing, .running, .waitingForInput, .waitingForApproval: return true
        default: return false
        }
    }

    /// Whether the chat box should accept a message right now.
    var canAcceptInput: Bool {
        if status == .waitingForInput { return true }
        guard task.allowsSteering else { return false }
        if isActive { return true }
        return engine != nil
    }

    var lastAssistantText: String? {
        blocks.last { $0.role == .assistant }?.text
    }

    // MARK: - Lifecycle

    func start() {
        guard runTask == nil, engine == nil else { return }
        let system = resolved(task.systemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { blocks.append(RunBlock(role: .system, text: system)) }
        blocks.append(RunBlock(role: .user, text: resolved(task.userPrompt)))
        if !variableValues.isEmpty {
            let summary = variableValues.keys.sorted().map { "\($0) = \(variableValues[$0] ?? "")" }
            addNotice("Variables: " + summary.joined(separator: " · "))
        }
        if unattended { addNotice("Scheduled run: commands run without asking for approval.") }
        if let timeoutSeconds { addNotice("Time limit: \(RunTimeout.label(seconds: timeoutSeconds)) of work.") }
        runTask = Task { await prepareAndRun() }
    }

    /// Suspends until the turn started by `start()` (or `send`) has ended. Returns at once if nothing is running.
    func waitUntilDone() async {
        await runTask?.value
    }

    func stop() {
        runTask?.cancel()
        if let continuation = pendingAnswer {
            pendingAnswer = nil
            continuation.resume(returning: "[The user stopped the run before answering.]")
        }
        resolveApproval(.deny)
    }

    /// Sends a steering message: answers a pending question, queues it while the model is busy,
    /// or starts a new turn when the model is idle.
    func send(_ text: String) {
        let trimmed = resolved(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let continuation = pendingAnswer {
            pendingAnswer = nil
            blocks.append(RunBlock(role: .user, text: trimmed))
            status = .running
            continuation.resume(returning: trimmed)
            return
        }

        guard task.allowsSteering else { return }

        if isActive {
            let block = RunBlock(role: .user, text: trimmed)
            block.note = "Queued — delivered after the current step"
            blocks.append(block)
            queuedInputs.append((block, trimmed))
            return
        }

        guard let engine, runTask == nil else { return }
        blocks.append(RunBlock(role: .user, text: trimmed))
        runTask = Task {
            do {
                try await perform(engine: engine, input: trimmed)
            } catch {
                handle(error)
            }
            runTask = nil
        }
    }

    // MARK: - Execution

    private func prepareAndRun() async {
        do {
            status = .preparing
            // A model known to lack something the task needs is not tried at all; one nobody has an answer for is.
            let requirements = task.effectiveRequirements
            if !requirements.isEmpty {
                let report = await providers.capabilities(for: model)
                let missing = report.unsupported(among: requirements)
                guard missing.isEmpty else { throw CapabilityError.unsupported(model: modelTitle, capabilities: missing) }
                let unreported = report.unreported(among: requirements)
                if !unreported.isEmpty {
                    addNotice("\(modelTitle) does not say whether it supports \(unreported.listed). Continuing anyway.")
                }
            }
            let toolbox = try await ToolBox.make(task: task, registry: registry, runner: self)
            toolNames = toolbox.entries.map(\.id) + (toolbox.includesAskUser ? [ToolBox.askUserName] : [])
            if !toolbox.entries.isEmpty {
                addNotice("\(toolbox.entries.count) tool\(toolbox.entries.count == 1 ? "" : "s") available from \(toolbox.serverNames.joined(separator: ", "))")
            }

            let summary = task.runOptions.summary(for: model)
            if !summary.isEmpty {
                addNotice("Run options: " + summary.joined(separator: " · "))
            }

            let systemPrompt = resolved(task.systemPrompt)
            let engine: any RunEngine
            switch model {
            case .appleFoundation:
                engine = FoundationEngine(runner: self, toolbox: toolbox, instructions: systemPrompt, options: task.runOptions.apple)
            case .openAICompatible(let endpointID, let id):
                let client = try providers.client(for: endpointID)
                contextWindow = await providers.contextWindow(for: model)
                engine = OpenAIEngine(
                    runner: self, toolbox: toolbox, client: client, model: id, systemPrompt: systemPrompt,
                    options: task.runOptions.openAICompatible, contextWindow: contextWindow?.tokens,
                    requiresVision: requirements.contains(.vision)
                )
            }
            self.engine = engine
            try await perform(engine: engine, input: resolved(task.userPrompt))
        } catch {
            handle(error)
        }
        runTask = nil
    }

    private func perform(engine: any RunEngine, input: String) async throws {
        status = .running
        try await engine.runTurn(userInput: input)
        var pending = dequeueInputs()
        while !pending.isEmpty {
            for text in pending {
                try Task.checkCancellation()
                try await engine.runTurn(userInput: text)
            }
            pending = dequeueInputs()
        }
        // A cancel that landed after the last checkpoint must not be reported as a normal finish.
        try Task.checkCancellation()
        status = task.allowsSteering ? .idle : .finished
    }

    private func handle(_ error: any Error) {
        if error is CancellationError {
            guard !timedOut else { return }
            status = .stopped
            addNotice("Stopped.")
        } else {
            if OpenAIEngine.isToolRejection(error) { noteCapability(.tools, supported: false) }
            status = .failed(error.localizedDescription)
            blocks.append(RunBlock(role: .error, text: error.localizedDescription))
        }
    }

    // MARK: - Time limit

    /// The clock runs while the model or a tool is working and pauses while the run waits for an approval.
    private func syncClock() {
        guard timeoutSeconds != nil else { return }
        switch status {
        case .preparing, .running: resumeClock()
        default: pauseClock()
        }
    }

    private func resumeClock() {
        guard watchdog == nil else { return }
        clockStartedAt = .now
        let remaining = timeoutRemaining
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.timeOut()
        }
    }

    private func pauseClock() {
        guard let watchdog else { return }
        watchdog.cancel()
        self.watchdog = nil
        if let clockStartedAt {
            timeoutRemaining = max(.zero, timeoutRemaining - clockStartedAt.duration(to: .now))
            self.clockStartedAt = nil
        }
    }

    /// The budget is spent: the run is over now, whatever the engine is still doing.
    private func timeOut() {
        guard isActive, let timeoutSeconds else { return }
        timedOut = true
        let message = "Timed out after \(RunTimeout.label(seconds: timeoutSeconds)) of work."
        blocks.append(RunBlock(role: .error, text: message))
        status = .failed(message)
        stop()
    }

    // MARK: - Engine callbacks

    /// Engines call this when a request shows what the model can or cannot do, so later runs are gated on it.
    func noteCapability(_ capability: ModelCapability, supported: Bool) {
        providers.learn(capability, supported: supported, for: model)
    }

    func beginAssistant() -> RunBlock {
        let block = RunBlock(role: .assistant)
        block.isStreaming = true
        blocks.append(block)
        return block
    }

    func finishAssistant(_ block: RunBlock) {
        block.isStreaming = false
        let empty = block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && block.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty { blocks.removeAll { $0.id == block.id } }
    }

    func beginToolCall(name: String, arguments: String) -> RunBlock {
        let block = RunBlock(role: .tool)
        block.toolName = name
        block.toolArguments = arguments
        block.isStreaming = true
        blocks.append(block)
        return block
    }

    func finishToolCall(_ block: RunBlock, result: MCPToolResult) {
        block.toolResult = result.text
        block.toolImages = result.images
        block.toolIsError = result.isError
        block.isStreaming = false
    }

    func addNotice(_ text: String) {
        blocks.append(RunBlock(role: .notice, text: text))
    }

    func dequeueInputs() -> [String] {
        let items = queuedInputs
        queuedInputs.removeAll()
        items.forEach { $0.block.note = nil }
        return items.map(\.text)
    }

    /// Called before a native tool that needs consent runs. Suspends until the user decides (or stops the run).
    func requestApproval(toolName: String, command: String, detail: String?) async -> ApprovalDecision {
        if approvedAllCommands || unattended { return .allow }
        let block = RunBlock(role: .approval, text: command)
        block.toolName = toolName
        block.note = detail
        block.approval = .pending
        blocks.append(block)
        status = .waitingForApproval
        let decision = await withCheckedContinuation { continuation in
            pendingApproval = (block, continuation)
        }
        block.approval = decision == .deny ? .denied : .allowed
        if decision == .allowAll { approvedAllCommands = true }
        if status == .waitingForApproval { status = .running }
        return decision
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.continuation.resume(returning: decision)
    }

    /// Called by the `ask_user` tool. Suspends until the user replies (or stops the run).
    func askUser(_ question: String) async -> String {
        blocks.append(RunBlock(role: .question, text: question))
        status = .waitingForInput
        return await withCheckedContinuation { continuation in
            pendingAnswer = continuation
        }
    }
}
