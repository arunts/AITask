import Foundation
import Observation

/// One entry in a run transcript. A class so streaming updates only re-render the affected row.
@Observable
final class RunBlock: Identifiable {
    enum Role {
        case system
        case user
        case assistant
        case tool
        case question
        /// A native tool waiting for (or having received) the user's go-ahead.
        case approval
        case notice
        case error
    }

    enum Approval {
        case pending
        case allowed
        case denied
    }

    let id = UUID()
    let role: Role
    var text: String
    var thinking = ""
    var toolName = ""
    var toolArguments = ""
    var toolResult: String?
    /// Images the tool returned, shown as thumbnails in the transcript.
    var toolImages: [MCPImage] = []
    var toolIsError = false
    var isStreaming = false
    var approval: Approval?
    /// Short caption, e.g. "Queued".
    var note: String?

    init(role: Role, text: String = "") {
        self.role = role
        self.text = text
    }
}
