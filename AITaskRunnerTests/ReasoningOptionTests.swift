import Foundation
import Testing
@testable import AITaskRunner

@Suite("Latest-thinking-only run option")
struct ReasoningOptionTests {
    private func assistant(_ reasoning: String, calls: Bool = true) -> JSONValue {
        var object: [String: JSONValue] = ["role": "assistant", "content": .string(""), "reasoning_content": .string(reasoning)]
        if calls { object["tool_calls"] = .array([]) }
        return .object(object)
    }

    @Test("Older assistant messages lose their reasoning; the latest keeps it")
    func dropsAllButTheLatest() {
        var messages: [JSONValue] = [
            ["role": "system", "content": .string("sys")],
            ["role": "user", "content": .string("go")],
            assistant("first plan"),
            ["role": "tool", "tool_call_id": .string("call_1"), "content": .string("result one")],
            assistant("second plan"),
            ["role": "tool", "tool_call_id": .string("call_2"), "content": .string("result two")],
            assistant("current plan"),
        ]
        let freed = OpenAIEngine.dropEarlierReasoning(from: &messages)
        #expect(freed > 0)
        #expect(messages[2]["reasoning_content"] == nil)
        #expect(messages[4]["reasoning_content"] == nil)
        #expect(messages[6]["reasoning_content"]?.string == "current plan")
        #expect(messages[3]["content"]?.string == "result one")
        #expect(messages.count == 7)

        // Nothing left to drop: a second pass is a no-op.
        let again = OpenAIEngine.dropEarlierReasoning(from: &messages)
        #expect(again == 0)
        #expect(messages[6]["reasoning_content"]?.string == "current plan")
    }

    @Test("The option is off by default, survives the task store, and shows in the run summary")
    func optionRoundTrip() throws {
        let legacy = try JSONDecoder().decode(RunOptions.self, from: Data(#"{"local": {"temperature": 0.2}}"#.utf8))
        #expect(!legacy.openAICompatible.keepsLatestReasoningOnly)
        #expect(legacy.openAICompatible.temperature == 0.2)

        var options = RunOptions()
        #expect(options.openAICompatible.isDefault)
        options.openAICompatible.keepsLatestReasoningOnly = true
        #expect(!options.openAICompatible.isDefault)
        #expect(options.openAICompatible.summary == ["latest thinking only"])
        #expect(options.openAICompatible.requestFields.isEmpty)

        let decoded = try JSONDecoder().decode(RunOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.openAICompatible.keepsLatestReasoningOnly)
    }
}
