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
                // No draft: the wizard saved or cancelled, or macOS restored the window at launch. The window goes.
                Color.clear
                    .frame(minWidth: 400, minHeight: 300)
                    .task {
                        // The window can re-open with a fresh draft while this placeholder is still on screen. A
                        // cancelled sleep means the wizard has taken over; dismissing then would run through the
                        // close interceptor, cancel the new draft and close the window the moment it appeared.
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        guard store.draft == nil else { return }
                        dismissWindow(id: Self.id)
                    }
            }
        }
    }
}
