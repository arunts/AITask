import SwiftUI

/// Hosts the task wizard in its own resizable window. The close button and ⌘W behave like the
/// wizard's Cancel: they confirm before discarding changes.
struct TaskEditorWindow: View {
    static let id = "task-editor"

    @Environment(TaskStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let draft = store.draft {
                TaskWizardView(draft: draft)
                    .id(draft.id)
            } else {
                // No draft: the wizard saved or cancelled, so the window goes.
                Color.clear
                    .frame(minWidth: 400, minHeight: 300)
                    .task {
                        try? await Task.sleep(for: .milliseconds(50))
                        dismissWindow(id: Self.id)
                    }
            }
        }
    }
}
