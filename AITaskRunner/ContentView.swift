import SwiftUI

struct ContentView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            TaskListView(selection: $store.selectedTaskID)
        } detail: {
            if let task = store.task(id: store.selectedTaskID) {
                TaskSummaryView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView {
                    Label("No Task Selected", systemImage: "list.bullet.rectangle.portrait")
                } description: {
                    Text("Create a task: name it, give the model a persona, write the job and pick its tools. Then run it on any connected model.")
                } actions: {
                    Button("New Task…") { store.beginNewTask() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onChange(of: store.editorRequests) {
            openWindow(id: TaskEditorWindow.id)
        }
        .sheet(item: $store.pendingImport) { source in
            TaskImportSheet(source: source)
        }
    }
}
