import Foundation
import Testing
@testable import AITaskRunner

@Suite("Run time limits")
struct RunTimeoutTests {
    @Test("The task's own limit wins over the app's, zero means no limit, and interactive tasks have none")
    func effective() {
        func limit(_ override: Int?, app: Int, interactive: Bool = false) -> Int? {
            RunTimeout.effective(for: AgentTask(userPrompt: "go", allowsSteering: interactive, runTimeoutSeconds: override), appDefault: app)
        }
        #expect(limit(nil, app: 0) == nil)
        #expect(limit(nil, app: 600) == 600)
        #expect(limit(0, app: 600) == nil)
        #expect(limit(120, app: 0) == 120)
        #expect(limit(-5, app: 600) == nil)
        #expect(limit(nil, app: 600, interactive: true) == nil)
        #expect(limit(120, app: 600, interactive: true) == nil)
        #expect(!AgentTask(userPrompt: "go", allowsSteering: true).canHaveTimeLimit)
    }

    @Test("Labels read naturally and minute conversions stay inside the stepper range")
    func labelsAndConversions() {
        #expect(RunTimeout.label(seconds: 1800) == "30 minutes")
        #expect(RunTimeout.label(seconds: 3600) == "1 hour")
        #expect(RunTimeout.label(seconds: 5400) == "1 hour 30 minutes")
        #expect(RunTimeout.label(seconds: 7200) == "2 hours")
        #expect(RunTimeout.label(seconds: 45) == "1 minute")
        #expect(RunTimeout.minutes(from: 0) == 1)
        #expect(RunTimeout.minutes(from: 90) == 2)
        #expect(RunTimeout.minutes(from: 1800) == 30)
        #expect(RunTimeout.seconds(fromMinutes: 0) == 60)
        #expect(RunTimeout.seconds(fromMinutes: 15) == 900)
        #expect(RunTimeout.seconds(fromMinutes: 100_000) == 24 * 60 * 60)
    }

    @Test("The per-task limit survives tasks.json, tolerates old files, and is never exported")
    func storedButNotExported() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let task = AgentTask(name: "T", userPrompt: "go", runTimeoutSeconds: 300)
        let decoded = try decoder.decode(AgentTask.self, from: try encoder.encode(task))
        #expect(decoded.runTimeoutSeconds == 300)

        let older = try decoder.decode(AgentTask.self, from: Data(#"{"userPrompt":"go"}"#.utf8))
        #expect(older.runTimeoutSeconds == nil)
        let unlimited = try decoder.decode(AgentTask.self, from: Data(#"{"userPrompt":"go","runTimeoutSeconds":0}"#.utf8))
        #expect(unlimited.runTimeoutSeconds == 0)
        let negative = try decoder.decode(AgentTask.self, from: Data(#"{"userPrompt":"go","runTimeoutSeconds":-1}"#.utf8))
        #expect(negative.runTimeoutSeconds == 0)

        let exported = String(decoding: TaskBundle.export(task, servers: [], includeSecrets: false), as: UTF8.self)
        #expect(!exported.contains("runTimeoutSeconds"))
        let imported = try TaskBundle.parse(exported, existingServers: [], builtinSettings: BuiltinToolSettings())
        #expect(imported.task.runTimeoutSeconds == nil)
    }
}
