import Foundation
import Observation

/// Persists saved tasks (recipes) as JSON in Application Support. Runs are never stored.
@Observable
final class TaskStore {
    private(set) var tasks: [AgentTask] = []
    var selectedTaskID: UUID?
    /// Task currently open in the wizard sheet, if any.
    var draft: TaskDraft?
    /// A task file the user chose; the preview sheet shows while this is set.
    var pendingImport: TaskImportSource?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL = AppPaths.supportDirectory) {
        fileURL = directory.appending(path: "tasks.json")
        tasks = JSONFile.load([AgentTask].self, from: fileURL) ?? []
        tasks.sort { $0.updatedAt > $1.updatedAt }
    }

    func task(id: UUID?) -> AgentTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    // MARK: - Wizard

    /// Bumped every time the editor is asked for, so the editor window opens or comes forward.
    private(set) var editorRequests = 0

    /// Starts a new draft unless one is already open; either way the editor is brought forward.
    func beginNewTask() {
        if draft == nil { draft = TaskDraft(task: AgentTask(), isNew: true) }
        editorRequests += 1
    }

    func beginEditing(id: UUID?) {
        guard let task = task(id: id) else { return }
        if draft == nil { draft = TaskDraft(task: task, isNew: false) }
        editorRequests += 1
    }

    /// Saves the wizard's result, inserting it if it is new, and closes the wizard.
    func commitDraft(_ task: AgentTask) {
        if tasks.contains(where: { $0.id == task.id }) {
            update(task)
            selectedTaskID = task.id
        } else {
            insert(task)
        }
        draft = nil
    }

    /// Adds a task (new or imported) at the top and selects it.
    func insert(_ task: AgentTask) {
        var stored = task
        stored.createdAt = .now
        stored.updatedAt = .now
        tasks.insert(stored, at: 0)
        selectedTaskID = stored.id
        scheduleSave()
    }

    func cancelDraft() {
        draft = nil
    }

    /// Replaces the stored copy. Skips the write when nothing but `updatedAt` would change.
    func update(_ task: AgentTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var stored = tasks[index]
        var incoming = task
        incoming.updatedAt = stored.updatedAt
        guard stored != incoming else { return }
        stored = task
        stored.updatedAt = .now
        tasks[index] = stored
        scheduleSave()
    }

    /// Notes that a scheduled task just ran. Only the time and how it ended are kept, never the run itself.
    /// Does not touch `updatedAt`, so the sidebar order stays put.
    func recordRun(id: UUID, at date: Date = .now, outcome: TaskSchedule.Outcome) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].schedule != nil else { return }
        tasks[index].schedule?.lastRunAt = date
        tasks[index].schedule?.lastOutcome = outcome
        scheduleSave()
    }

    func delete(id: UUID) {
        tasks.removeAll { $0.id == id }
        if selectedTaskID == id { selectedTaskID = tasks.first?.id }
        scheduleSave()
    }

    @discardableResult
    func duplicate(id: UUID) -> AgentTask? {
        guard let original = task(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = original.displayName + " copy"
        copy.createdAt = .now
        copy.updatedAt = .now
        tasks.insert(copy, at: 0)
        selectedTaskID = copy.id
        scheduleSave()
        return copy
    }

    /// Writes immediately (used right before a run so the window sees the latest prompt).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        JSONFile.save(tasks, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = tasks
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            JSONFile.save(snapshot, to: url)
        }
    }
}
