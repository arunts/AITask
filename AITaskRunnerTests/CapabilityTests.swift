import Foundation
import Testing
@testable import AITaskRunner

// MARK: - Reports

@Suite("Capability reports")
struct CapabilityReportTests {
    @Test("A report answers for what it names and stays unknown for the rest")
    func reportBasics() {
        let report = CapabilityReport(supported: [.tools], unsupported: [.vision], source: "Ollama")
        #expect(report[.tools].support == .supported)
        #expect(report[.tools].source == "Ollama")
        #expect(report[.vision].support == .unsupported)
        #expect(report[.thinking].support == .unknown)
        #expect(report[.thinking].source == nil)
        #expect(report.unsupported(among: [.tools, .vision, .thinking]) == [.vision])
        #expect(report.unreported(among: [.tools, .vision, .thinking]) == [.thinking])
        #expect(report.satisfies([.tools, .thinking]))
        #expect(!report.satisfies([.vision]))
        #expect(CapabilityReport.unknown.satisfies([.tools, .vision, .thinking]))
    }

    @Test("A run's finding replaces the endpoint's answer for that capability only")
    func learning() {
        var report = CapabilityReport(supported: [.tools, .vision], unsupported: [.thinking], source: "Ollama")
        report.set(.vision, supported: false, source: "a run")
        #expect(report[.vision].support == .unsupported)
        #expect(report[.vision].source == "a run")
        #expect(report[.tools].support == .supported)
        #expect(report[.tools].source == "Ollama")
    }

    @Test("Names from a file parse case-insensitively and unknown ones are reported")
    func parsing() {
        let parsed = ModelCapability.parse(["Vision", " tools ", "telepathy", ""])
        #expect(parsed.capabilities == [.vision, .tools])
        #expect(parsed.unknown == ["telepathy"])
        #expect([ModelCapability.thinking, .tools, .vision].listed == "tool calling, vision and thinking")
        #expect([ModelCapability.vision].listed == "vision")
        #expect(([] as [ModelCapability]).listed == "")
    }
}

// MARK: - Discovery

@Suite("Capability discovery")
struct CapabilityDiscoveryTests {
    @Test("Ollama's capabilities list answers for all three")
    func ollama() throws {
        let show: JSONValue = ["capabilities": ["completion", "vision", "tools", "thinking"], "model_info": [:]]
        let report = try #require(OpenAICompatibleClient.capabilities(fromOllamaShow: show))
        #expect(report[.tools].support == .supported)
        #expect(report[.vision].support == .supported)
        #expect(report[.thinking].support == .supported)
        #expect(report[.tools].source == "Ollama")

        let textOnly = try #require(OpenAICompatibleClient.capabilities(fromOllamaShow: ["capabilities": ["completion"]]))
        #expect(textOnly.unsupported(among: [.tools, .vision, .thinking]) == [.tools, .vision, .thinking])
        #expect(OpenAICompatibleClient.capabilities(fromOllamaShow: ["parameters": "num_ctx 4096"]) == nil)
    }

    @Test("LM Studio's model type says whether it takes images; a capabilities object says more")
    func lmStudio() throws {
        let v0: JSONValue = ["data": [
            ["id": "qwen2-vl", "type": "vlm"],
            ["id": "qwen3", "type": "llm"],
            ["id": "embed", "type": "embeddings"],
        ]]
        let vlm = try #require(OpenAICompatibleClient.capabilities(fromLMStudio: v0, model: "qwen2-vl"))
        #expect(vlm[.vision].support == .supported)
        #expect(vlm[.tools].support == .unknown)
        #expect(vlm[.vision].source == "LM Studio")
        let llm = try #require(OpenAICompatibleClient.capabilities(fromLMStudio: v0, model: "qwen3"))
        #expect(llm[.vision].support == .unsupported)
        #expect(OpenAICompatibleClient.capabilities(fromLMStudio: v0, model: "embed") == nil)
        #expect(OpenAICompatibleClient.capabilities(fromLMStudio: v0, model: "missing") == nil)

        let v1: JSONValue = ["models": [
            ["key": "gemma", "type": "llm", "capabilities": ["trained_for_tool_use": true, "vision": true]],
            ["key": "listed", "capabilities": ["vision", "reasoning"]],
        ]]
        let gemma = try #require(OpenAICompatibleClient.capabilities(fromLMStudio: v1, model: "gemma"))
        #expect(gemma[.tools].support == .supported)
        #expect(gemma[.vision].support == .supported) // the capabilities object outranks "type": "llm"
        #expect(gemma[.thinking].support == .unknown)
        let listed = try #require(OpenAICompatibleClient.capabilities(fromLMStudio: v1, model: "listed"))
        #expect(listed[.vision].support == .supported)
        #expect(listed[.thinking].support == .supported)
        #expect(listed[.tools].support == .unsupported)
    }

    @Test("llama.cpp reports vision only")
    func llamaCpp() throws {
        let report = try #require(OpenAICompatibleClient.capabilities(fromLlamaProps: ["modalities": ["vision": true, "audio": false]]))
        #expect(report[.vision].support == .supported)
        #expect(report[.tools].support == .unknown)
        let none = try #require(OpenAICompatibleClient.capabilities(fromLlamaProps: ["modalities": ["vision": false]]))
        #expect(none[.vision].support == .unsupported)
        #expect(OpenAICompatibleClient.capabilities(fromLlamaProps: ["default_generation_settings": [:]]) == nil)
    }

    @Test("Only a 400/422 that blames tool support counts as a tool rejection")
    func toolRejection() {
        #expect(OpenAIEngine.isToolRejection(OpenAICompatibleError.http(400, "registry.ollama.ai/library/llama2:latest does not support tools")))
        #expect(OpenAIEngine.isToolRejection(OpenAICompatibleError.http(422, "Tools are not supported by this model")))
        #expect(!OpenAIEngine.isToolRejection(OpenAICompatibleError.http(400, "tools param requires --jinja flag")))
        #expect(!OpenAIEngine.isToolRejection(OpenAICompatibleError.http(500, "does not support tools")))
        #expect(!OpenAIEngine.isToolRejection(OpenAICompatibleError.server("does not support tools")))
    }
}

// MARK: - Tasks

@Suite("Task requirements")
struct TaskRequirementTests {
    @Test("Attached tools and steering imply tool calling; declared extras stay separate")
    func effectiveRequirements() {
        var task = AgentTask(userPrompt: "go")
        #expect(task.effectiveRequirements.isEmpty)
        #expect(task.declaredRequirements.isEmpty)

        task.allowsSteering = true
        #expect(task.effectiveRequirements == [.tools])
        #expect(task.declaredRequirements.isEmpty)

        task.allowsSteering = false
        task.toolAttachments = [ToolAttachment(serverID: BuiltinToolPack.shell.id)]
        task.requiredCapabilities = [.vision, .tools]
        #expect(task.effectiveRequirements == [.tools, .vision])
        #expect(task.declaredRequirements == [.vision])
        #expect(task.traits() == "Tools · Vision")
    }

    @Test("Requirements survive the task store's JSON and unknown names are dropped, not fatal")
    func storeRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let task = AgentTask(name: "T", userPrompt: "go", requiredCapabilities: [.thinking, .vision])
        let data = try encoder.encode(task)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""requiredCapabilities":["vision","thinking"]"#))
        let decoded = try decoder.decode(AgentTask.self, from: data)
        #expect(decoded.requiredCapabilities == [.vision, .thinking])
        #expect(decoded.id == task.id)
        #expect(decoded.name == task.name)

        let older = try decoder.decode(AgentTask.self, from: Data(#"{"id":"\#(UUID().uuidString)","userPrompt":"go"}"#.utf8))
        #expect(older.requiredCapabilities.isEmpty)
        let newer = try decoder.decode(AgentTask.self, from: Data(#"{"userPrompt":"go","requiredCapabilities":["vision","telepathy"]}"#.utf8))
        #expect(newer.requiredCapabilities == [.vision])
    }

    @Test("Export writes the effective set and import reads it back, warning about unknown names")
    func bundleRoundTrip() throws {
        let task = AgentTask(
            name: "Look",
            userPrompt: "Describe the screenshot from shell__run.",
            toolAttachments: [ToolAttachment(serverID: BuiltinToolPack.shell.id)],
            requiredCapabilities: [.vision]
        )
        let data = TaskBundle.export(task, servers: [], includeSecrets: false)
        let json = try JSONValue.parse(data)
        #expect(json["task"]?["requires"]?.array?.compactMap(\.string) == ["tools", "vision"])

        let imported = try TaskBundle.parse(String(decoding: data, as: UTF8.self), existingServers: [], builtinSettings: BuiltinToolSettings())
        #expect(imported.task.requiredCapabilities == [.tools, .vision])
        #expect(imported.task.effectiveRequirements == [.tools, .vision])
        #expect(imported.warnings.isEmpty)

        let odd = """
        {"format": "AITaskDefinition", "version": 1, "task": {"userPrompt": "go", "requires": ["Thinking", "x-ray"]}}
        """
        let parsed = try TaskBundle.parse(odd, existingServers: [], builtinSettings: BuiltinToolSettings())
        #expect(parsed.task.requiredCapabilities == [.thinking])
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("x-ray"))

        let plain = try TaskBundle.parse(#"{"format": "AITaskDefinition", "version": 1, "task": {"userPrompt": "go"}}"#, existingServers: [], builtinSettings: BuiltinToolSettings())
        #expect(plain.task.requiredCapabilities.isEmpty)
    }
}
