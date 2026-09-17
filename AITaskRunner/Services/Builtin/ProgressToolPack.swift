import Foundation

/// How far the model says a multi-step job has got, as last reported through `progress__update`.
nonisolated struct RunProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var isComplete: Bool { done >= total }
    /// "3/10"
    var text: String { "\(done)/\(total)" }
}

/// Lets the model report progress on a multi-step job. Nothing runs; the run window shows the value.
nonisolated enum ProgressToolPack {
    static let updateToolName = "update"

    static let definitions: [BuiltinTool] = [
        BuiltinTool(
            name: "update",
            description: "Report how far a multi-step job has got. Call it each time a step, file or item is finished, with how many are done so far and how many there are in total. The user sees it as done/total at the top of the run window.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "done": ["type": "integer", "description": "Steps or items finished so far, from 0 up to total."],
                    "total": ["type": "integer", "description": "Total number of steps or items in the job. At least 1."],
                ],
                "required": ["done", "total"],
            ]
        ),
    ]

    /// Validates a call. Returns the tool result the model reads and, when the arguments are sound, the progress to show.
    static func call(_ tool: String, arguments: JSONValue) -> (result: MCPToolResult, progress: RunProgress?) {
        guard tool == updateToolName else {
            return (MCPToolResult(text: "Unknown progress tool “\(tool)”.", isError: true), nil)
        }
        guard let total = integer(arguments["total"]) else {
            return (MCPToolResult(text: "Pass total: the number of steps or items in the job, as an integer of at least 1.", isError: true), nil)
        }
        guard total >= 1 else {
            return (MCPToolResult(text: "total must be at least 1.", isError: true), nil)
        }
        guard let done = integer(arguments["done"]) else {
            return (MCPToolResult(text: "Pass done: how many of the \(total) steps are finished, as an integer from 0 to \(total).", isError: true), nil)
        }
        guard (0...total).contains(done) else {
            return (MCPToolResult(text: "done must be between 0 and total (\(total)); got \(done).", isError: true), nil)
        }
        let progress = RunProgress(done: done, total: total)
        return (MCPToolResult(text: "Progress: \(progress.text).", isError: false), progress)
    }

    /// An integer argument; small models sometimes send numbers as strings, which are accepted too.
    private static func integer(_ value: JSONValue?) -> Int? {
        if let int = value?.int { return int }
        if let text = value?.string { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
