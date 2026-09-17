import Foundation
import Testing
@testable import AITaskRunner

@Suite("Reporting progress")
struct ProgressToolTests {
    @Test("The pack is found by slug and id, needs no approval, and its only tool is update")
    func progressPackLookup() {
        #expect(BuiltinToolPack(slug: "progress") == .progress)
        #expect(BuiltinToolPack(id: BuiltinToolPack.progress.id) == .progress)
        #expect(BuiltinToolPack.progress.config.slug == "progress")
        #expect(BuiltinToolPack.progress.tools.map(\.name) == ["update"])
        #expect(!BuiltinToolPack.progress.requiresApproval("update"))
    }

    @Test("The pack is on by default and settings saved before it existed still decode")
    func progressPackDefaultsOn() throws {
        let legacy = Data(#"{"shellEnabled": true, "workingDirectory": "/tmp", "shellRequiresApproval": true, "shellTimeoutSeconds": 30, "contextEnabled": false}"#.utf8)
        let settings = try JSONDecoder().decode(BuiltinToolSettings.self, from: legacy)
        #expect(settings.isEnabled(.progress))
        #expect(!settings.isEnabled(.context))

        var changed = settings
        changed.progressEnabled = false
        let roundTrip = try JSONDecoder().decode(BuiltinToolSettings.self, from: JSONEncoder().encode(changed))
        #expect(!roundTrip.isEnabled(.progress))
    }

    @Test("A sound call yields the value to show and a short confirmation")
    func validCall() {
        let (result, progress) = ProgressToolPack.call("update", arguments: ["done": 3, "total": 10])
        #expect(!result.isError)
        #expect(result.text == "Progress: 3/10.")
        #expect(progress == RunProgress(done: 3, total: 10))
        #expect(progress?.fraction == 0.3)
        #expect(progress?.isComplete == false)
    }

    @Test("Numbers sent as strings are accepted, and done == total counts as complete")
    func stringNumbers() {
        let (result, progress) = ProgressToolPack.call("update", arguments: ["done": "4", "total": " 4"])
        #expect(!result.isError)
        #expect(progress == RunProgress(done: 4, total: 4))
        #expect(progress?.isComplete == true)
        #expect(progress?.text == "4/4")
    }

    @Test("Bad arguments are refused with an error the model can act on, and nothing is shown", arguments: [
        JSONValue.object(["done": 1]),
        ["total": 5],
        ["done": 2, "total": 0],
        ["done": 6, "total": 5],
        ["done": -1, "total": 5],
        ["done": 1.5, "total": 5],
        ["done": "many", "total": 5],
    ])
    func invalidCall(arguments: JSONValue) {
        let (result, progress) = ProgressToolPack.call("update", arguments: arguments)
        #expect(result.isError)
        #expect(progress == nil)
    }

    @Test("An unknown tool name in the pack is an error")
    func unknownTool() {
        let (result, progress) = ProgressToolPack.call("reset", arguments: [:])
        #expect(result.isError)
        #expect(progress == nil)
    }
}
