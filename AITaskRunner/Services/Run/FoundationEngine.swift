import Foundation
import FoundationModels

nonisolated enum FoundationEngineError: LocalizedError {
    case contextFull

    var errorDescription: String? {
        switch self {
        case .contextFull:
            return "The Apple model's context window is full. Attach fewer tools, shorten the prompts, or switch to an endpoint model with a larger window."
        }
    }
}

/// Runs a task on Apple's on-device model. Tool calls are executed by the framework inside the session.
final class FoundationEngine: RunEngine {
    /// Apple's published limit for the on-device model. The framework does not report it at runtime;
    /// used only to colour the context gauge, never shown as a fact.
    static let documentedContextWindow = 4_096

    private unowned let runner: TaskRunner
    private let session: LanguageModelSession
    private let generationOptions: GenerationOptions

    init(runner: TaskRunner, toolbox: ToolBox, instructions: String, options: RunOptions.AppleOptions) {
        self.runner = runner
        self.generationOptions = options.generationOptions
        let (tools, skipped) = toolbox.foundationTools(maxResultCharacters: 4_000)
        if !skipped.isEmpty {
            runner.addNotice("Skipped tools whose schema the Apple model cannot use: \(skipped.joined(separator: ", "))")
        }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionText: String? = trimmed.isEmpty ? nil : trimmed
        session = LanguageModelSession(model: .default, tools: tools, instructions: instructionText)
    }

    func runTurn(userInput: String) async throws {
        await reportTranscriptSize()
        var block: RunBlock?
        let stream = session.streamResponse(to: userInput, options: generationOptions)
        do {
            for try await snapshot in stream {
                try Task.checkCancellation()
                if block == nil { block = runner.beginAssistant() }
                block?.text = snapshot.content
            }
        } catch {
            if let block { runner.finishAssistant(block) }
            if let generationError = error as? LanguageModelSession.GenerationError,
               case .exceededContextWindowSize = generationError {
                throw FoundationEngineError.contextFull
            }
            throw error
        }
        if let block { runner.finishAssistant(block) }
        await reportTranscriptSize()
    }

    /// Exact size of everything in the session so far, counted by the framework's own tokenizer.
    private func reportTranscriptSize() async {
        guard let tokens = try? await SystemLanguageModel.default.tokenCount(for: session.transcript) else { return }
        runner.reportContext(used: tokens, isExact: true)
    }
}

extension RunOptions.AppleOptions {
    /// Maps the saved settings onto FoundationModels' `GenerationOptions`; unset fields stay at framework defaults.
    var generationOptions: GenerationOptions {
        let seed64 = seed.map { UInt64(max(0, $0)) }
        let mode: GenerationOptions.SamplingMode?
        switch sampling {
        case .greedy:
            mode = .greedy
        case .topK:
            mode = .random(top: max(1, topK ?? 40), seed: seed64)
        case .topP:
            mode = .random(probabilityThreshold: min(max(topP ?? 0.9, 0), 1), seed: seed64)
        case nil:
            mode = nil
        }
        return GenerationOptions(
            sampling: mode,
            temperature: temperature.map { max(0, $0) },
            maximumResponseTokens: maxResponseTokens.map { max(1, $0) }
        )
    }
}
