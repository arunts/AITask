import Foundation
import Observation

/// Runs scheduled tasks while the app is open. One run at a time, never alongside a run window,
/// and only when the task's chosen model is available. Transcripts are discarded when a run ends;
/// the store keeps just the time and outcome.
@Observable
final class TaskScheduler {
    private let store: TaskStore
    private let registry: MCPRegistry
    private let settings: AppSettings
    private let providers: ProviderHub

    /// The scheduled run in progress, if any.
    private(set) var activeRunner: TaskRunner?
    private(set) var activeTaskID: UUID?
    /// Run windows the user has open. Scheduled runs wait until they finish.
    private(set) var manualRunsActive = 0

    private var loop: Task<Void, Never>?

    init(store: TaskStore, registry: MCPRegistry, settings: AppSettings, providers: ProviderHub) {
        self.store = store
        self.registry = registry
        self.settings = settings
        self.providers = providers
    }

    /// Checks for due tasks now and then every `interval`. Safe to call again; it restarts the loop.
    func start(every interval: Duration = .seconds(30), initialDelay: Duration = .seconds(5)) {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - Run windows

    func manualRunStarted() { manualRunsActive += 1 }
    func manualRunEnded() { manualRunsActive = max(0, manualRunsActive - 1) }

    // MARK: - Status for the UI

    func isRunning(_ taskID: UUID) -> Bool { activeTaskID == taskID }

    /// The model the schedule will use, if it is available right now.
    func availableModel(for task: AgentTask) -> ModelChoice? {
        guard let raw = task.preferredModel, let choice = ModelChoice(rawValue: raw), providers.choices.contains(choice) else { return nil }
        return choice
    }

    /// Requirements the chosen model is known not to meet; the run is held while any remain.
    func unmetRequirements(for task: AgentTask, model: ModelChoice) -> [ModelCapability] {
        providers.knownCapabilities(for: model).unsupported(among: task.effectiveRequirements)
    }

    /// Why a due task is waiting instead of running, or nil when nothing holds it.
    func holdReason(for task: AgentTask) -> String? {
        if isRunning(task.id) { return nil }
        guard let model = availableModel(for: task) else {
            let name = task.preferredModel.flatMap { ModelChoice(rawValue: $0) }.map { settings.displayName(for: $0) }
            return name.map { "Waiting for \($0) to be available" } ?? "No model chosen"
        }
        let unmet = unmetRequirements(for: task, model: model)
        if !unmet.isEmpty { return "\(settings.displayName(for: model)) does not support \(unmet.listed)" }
        if activeRunner != nil { return "Waiting for another scheduled run to finish" }
        if manualRunsActive > 0 { return "Waiting for the open run window to finish" }
        return nil
    }

    func stopActiveRun() {
        activeRunner?.stop()
    }

    // MARK: - Loop

    private func tick() async {
        guard activeRunner == nil, manualRunsActive == 0 else { return }
        let now = Date()
        let due = store.tasks
            .filter { $0.canBeScheduled && ($0.schedule?.isDue(at: now) ?? false) }
            .sorted { ($0.schedule?.nextRunAt ?? now) < ($1.schedule?.nextRunAt ?? now) }
        for task in due {
            guard let model = availableModel(for: task), unmetRequirements(for: task, model: model).isEmpty else { continue }
            await run(task, model: model)
            return // one per tick; the next tick picks up anything else that is due
        }
    }

    private func run(_ task: AgentTask, model: ModelChoice) async {
        let runner = TaskRunner(task: task, model: model, registry: registry, settings: settings, providers: providers, unattended: true)
        activeRunner = runner
        activeTaskID = task.id
        runner.start()
        await runner.waitUntilDone()

        let outcome: TaskSchedule.Outcome
        switch runner.status {
        case .failed(let reason): outcome = .failed(reason)
        case .stopped: outcome = .stopped
        default: outcome = .succeeded
        }
        store.recordRun(id: task.id, at: .now, outcome: outcome)
        activeRunner = nil
        activeTaskID = nil
    }
}
