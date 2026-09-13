import Foundation
import Testing
@testable import AITaskRunner

@Suite("Clearing context on request")
struct ContextClearTests {
    private typealias Call = OpenAIEngine.PendingCall

    private static let system: JSONValue = ["role": "system", "content": "Be brief."]
    private static let task: JSONValue = ["role": "user", "content": "Summarise every file in ~/Notes, one at a time."]

    /// A conversation two files in: the task, a listing, a read, and a round that reads a second file and then clears.
    private static func conversation(withSystem: Bool) -> [JSONValue] {
        var messages: [JSONValue] = withSystem ? [system] : []
        messages += [
            task,
            ["role": "assistant", "content": "", "reasoning_content": "list first", "tool_calls": .array([OpenAIEngine.toolCallJSON(Call(id: "c1", name: "shell__run", arguments: "{\"command\":\"ls\"}"))])],
            ["role": "tool", "tool_call_id": "c1", "content": "a.md\nb.md"],
            ["role": "assistant", "content": "", "tool_calls": .array([OpenAIEngine.toolCallJSON(Call(id: "c2", name: "shell__run", arguments: "{\"command\":\"cat a.md\"}"))])],
            ["role": "tool", "tool_call_id": "c2", "content": .string(String(repeating: "lorem ", count: 2_000))],
            ["role": "assistant", "content": "Done with a.md.", "tool_calls": .array([
                OpenAIEngine.toolCallJSON(Call(id: "c3", name: "shell__run", arguments: "{\"command\":\"cat > a.summary.md <<'EOF'\\n…\\nEOF\"}")),
                OpenAIEngine.toolCallJSON(Call(id: "c4", name: "context__clear", arguments: "{\"note\":\"Done: a.md. Next: b.md.\"}")),
                OpenAIEngine.toolCallJSON(Call(id: "c5", name: "shell__run", arguments: "{\"command\":\"cat b.md\"}")),
            ])],
            ["role": "tool", "tool_call_id": "c3", "content": "exit code: 0"],
        ]
        return messages
    }

    @Test("Only the system prompt, the task, the clear call and later calls in its round survive")
    func clearKeepsTheEssentials() {
        let clear = Call(id: "c4", name: "context__clear", arguments: "{\"note\":\"Done: a.md. Next: b.md.\"}")
        let later = Call(id: "c5", name: "shell__run", arguments: "{\"command\":\"cat b.md\"}")
        let (kept, dropped) = OpenAIEngine.cleared(
            messages: Self.conversation(withSystem: true), firstUserMessage: Self.task,
            call: clear, remaining: [clear, later], note: "Done: a.md. Next: b.md."
        )

        #expect(kept.count == 4)
        #expect(kept[0] == Self.system)
        #expect(kept[1] == Self.task)
        #expect(kept[2]["role"]?.string == "assistant")
        #expect(kept[2]["reasoning_content"] == nil)
        #expect(kept[2]["tool_calls"]?.array?.compactMap { $0["id"]?.string } == ["c4", "c5"])
        #expect(kept[3]["role"]?.string == "tool")
        #expect(kept[3]["tool_call_id"]?.string == "c4")
        let result = kept[3]["content"]?.string ?? ""
        #expect(result.hasSuffix("Your note:\nDone: a.md. Next: b.md."))
        #expect(result.contains("\(dropped) earlier messages dropped"))
        // Everything but system, task and the (rewritten) assistant message: 5 of the 8.
        #expect(dropped == 5)
    }

    @Test("Without a system prompt the task prompt comes first")
    func clearWithoutSystemPrompt() {
        let clear = Call(id: "c4", name: "context__clear", arguments: "{\"note\":\"n\"}")
        let (kept, dropped) = OpenAIEngine.cleared(
            messages: Self.conversation(withSystem: false), firstUserMessage: Self.task,
            call: clear, remaining: [clear], note: "n"
        )
        #expect(kept.count == 3)
        #expect(kept[0] == Self.task)
        #expect(kept[1]["tool_calls"]?.array?.count == 1)
        #expect(dropped == 5)
        #expect(kept[2]["content"]?.string == ContextToolPack.clearedResultText(dropped: 5, note: "n"))
    }

    @Test("The context pack is on by default and settings saved before it existed still decode")
    func contextPackDefaultsOn() throws {
        let legacy = Data(#"{"shellEnabled": false, "workingDirectory": "/tmp", "shellRequiresApproval": true, "shellTimeoutSeconds": 30}"#.utf8)
        let settings = try JSONDecoder().decode(BuiltinToolSettings.self, from: legacy)
        #expect(settings.isEnabled(.context))
        #expect(!settings.isEnabled(.shell))

        var changed = settings
        changed.contextEnabled = false
        let roundTrip = try JSONDecoder().decode(BuiltinToolSettings.self, from: JSONEncoder().encode(changed))
        #expect(!roundTrip.isEnabled(.context))
    }

    @Test("The pack is found by slug and id, and its only tool is clear")
    func contextPackLookup() {
        #expect(BuiltinToolPack(slug: "context") == .context)
        #expect(BuiltinToolPack(id: BuiltinToolPack.context.id) == .context)
        #expect(BuiltinToolPack.context.config.slug == "context")
        #expect(BuiltinToolPack.context.tools.map(\.name) == ["clear"])
        #expect(!BuiltinToolPack.context.requiresApproval("clear"))
    }
}
