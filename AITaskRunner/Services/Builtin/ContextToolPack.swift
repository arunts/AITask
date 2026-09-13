import Foundation

/// Lets the model reset its own conversation mid-run. The engine handles the call; nothing here executes.
nonisolated enum ContextToolPack {
    static let clearToolName = "clear"

    static let definitions: [BuiltinTool] = [
        BuiltinTool(
            name: "clear",
            description: "Forget everything in this conversation except the system prompt, the original task and the note you pass here. Call it after finishing one unit of work (a file, a page, an item) and before starting the next, so earlier content stops filling the context window. Put in the note everything you still need: what is done, what comes next, and any result not yet written elsewhere.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "note": ["type": "string", "description": "What to carry forward: what is done, what comes next, and anything not yet saved. This is all you will remember."],
                ],
                "required": ["note"],
            ]
        ),
    ]

    /// The tool result the model reads after a clear; the note is the only state that survives.
    static func clearedResultText(dropped: Int, note: String) -> String {
        "Context cleared: \(dropped) earlier message\(dropped == 1 ? "" : "s") dropped. You still have the system prompt and the original task. Your note:\n\(note)"
    }

    static let blankNoteText = "Nothing was cleared: pass a note saying what is done and what comes next."
}
