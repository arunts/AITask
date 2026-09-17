import SwiftUI

/// Toolbar button that opens the per-task generation settings for the selected model.
/// Shows only the knobs the selected model's API actually accepts.
struct RunOptionsButton: View {
    @Environment(AppSettings.self) private var settings
    @Binding var options: RunOptions
    let choice: ModelChoice?

    @State private var showing = false

    private var isCustomized: Bool {
        guard let choice else { return false }
        return !options.isDefault(for: choice)
    }

    private var helpText: String {
        guard let choice else { return "Pick a model to adjust its run options" }
        let summary = options.summary(for: choice)
        return summary.isEmpty
            ? "Run options for \(settings.displayName(for: choice)) (all defaults)"
            : "Run options: " + summary.joined(separator: "\n")
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label("Run Options", systemImage: "slider.horizontal.3")
                .foregroundStyle(isCustomized ? AnyShapeStyle(.tint) : AnyShapeStyle(.foreground))
        }
        .disabled(choice == nil)
        .help(helpText)
        .popover(isPresented: $showing) {
            if let choice {
                RunOptionsForm(options: $options, choice: choice)
            }
        }
    }
}

private struct RunOptionsForm: View {
    @Environment(AppSettings.self) private var settings
    @Binding var options: RunOptions
    let choice: ModelChoice

    @State private var stopText = ""
    @State private var stopOn = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Options")
                    .textStyle(.headline)
                Text(choice.isApple ? "Apple Foundation Model · GenerationOptions" : "\(settings.displayName(for: choice)) · chat/completions")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Form {
                if choice.isApple {
                    appleSections
                } else {
                    openAICompatibleSections
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("Unchecked options use the provider's default.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All") { reset() }
                    .disabled(options.isDefault(for: choice))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: choice.isApple ? 520 : 700)
        .onAppear {
            stopText = options.openAICompatible.stopSequences.joined(separator: "\n")
            stopOn = !options.openAICompatible.stopSequences.isEmpty
        }
        .onChange(of: stopText) {
            options.openAICompatible.stopSequences = stopText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }

    // MARK: - OpenAI-compatible

    @ViewBuilder
    private var openAICompatibleSections: some View {
        Section {
            SliderOption(
                title: "Temperature", hint: "Randomness: 0 is deterministic, 2 is very random.",
                value: $options.openAICompatible.temperature, range: 0...2, step: 0.05, initial: 0.8
            )
            SliderOption(
                title: "Top P", hint: "Only tokens within this probability mass are considered.",
                value: $options.openAICompatible.topP, range: 0...1, step: 0.01, initial: 0.9
            )
            IntegerOption(
                title: "Seed", hint: "Same seed and settings give repeatable output where the server supports it.",
                value: $options.openAICompatible.seed, range: 0...1_000_000_000, initial: 42
            )
        } header: {
            Text("Sampling")
        } footer: {
            Text("Sent as temperature, top_p and seed.")
            .textStyle(.callout)
        }
        Section {
            IntegerOption(
                title: "Max tokens", hint: "The reply is cut off after this many tokens.",
                value: $options.openAICompatible.maxTokens, range: 1...1_000_000_000, initial: 1024
            )
            TextOption(
                title: "Stop sequences", hint: "Generation stops when any of these appears. One per line.",
                isOn: stopEnabled, text: $stopText, placeholder: "###\nEND"
            )
        } header: {
            Text("Length")
        } footer: {
            Text("Sent as max_tokens and stop.")
            .textStyle(.callout)
        }
        Section {
            SliderOption(
                title: "Presence penalty", hint: "Positive values nudge the model toward new topics.",
                value: $options.openAICompatible.presencePenalty, range: -2...2, step: 0.1, initial: 0
            )
            SliderOption(
                title: "Frequency penalty", hint: "Positive values discourage repeating the same words.",
                value: $options.openAICompatible.frequencyPenalty, range: -2...2, step: 0.1, initial: 0
            )
        } header: {
            Text("Repetition")
        } footer: {
            Text("Sent as presence_penalty and frequency_penalty.")
            .textStyle(.callout)
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $options.openAICompatible.keepsLatestReasoningOnly) {
                    Text("Keep only the latest thinking")
                }
                .toggleStyle(.checkbox)
                Text("Each request carries the thinking from the most recent reply only; older reasoning is dropped whether or not the window is full. Saves context on long tool-calling runs. The model rebuilds its plan from the tool results, so keep this off for tasks whose reasoning holds state that nothing else records.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        } header: {
            Text("Context")
        } footer: {
            Text("Applied by the app before each request; nothing is sent to the server. Off: thinking stays until the context is nearly full.")
            .textStyle(.callout)
        }
    }

    private var stopEnabled: Binding<Bool> {
        Binding(
            get: { stopOn },
            set: { on in
                stopOn = on
                if !on {
                    stopText = ""
                    options.openAICompatible.stopSequences = []
                }
            }
        )
    }

    // MARK: - Apple Foundation Models

    @ViewBuilder
    private var appleSections: some View {
        Section {
            Picker("Sampling mode", selection: $options.apple.sampling) {
                Text("Default").tag(RunOptions.AppleOptions.Sampling?.none)
                ForEach(RunOptions.AppleOptions.Sampling.allCases, id: \.self) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            if options.apple.sampling == .topK {
                IntegerOption(
                    title: "Top K", hint: "Each token is drawn from the K most likely candidates.",
                    value: $options.apple.topK, range: 1...1_000_000_000, initial: 40
                )
            }
            if options.apple.sampling == .topP {
                SliderOption(
                    title: "Probability threshold", hint: "Each token is drawn from the smallest set whose probabilities add up to this.",
                    value: $options.apple.topP, range: 0...1, step: 0.01, initial: 0.9
                )
            }
            if options.apple.usesSeed {
                IntegerOption(
                    title: "Seed", hint: "Same seed and settings give repeatable output.",
                    value: $options.apple.seed, range: 0...1_000_000_000, initial: 42
                )
            }
            SliderOption(
                title: "Temperature", hint: "Randomness: 0 is deterministic, 2 is very random.",
                value: $options.apple.temperature, range: 0...2, step: 0.05, initial: 0.8
            )
        } header: {
            Text("Sampling")
        } footer: {
            Text("Default lets the framework choose how each token is picked.")
            .textStyle(.callout)
        }
        Section {
            SliderOption(
                title: "Max response tokens", hint: "The prompt and the reply share the same 4,096-token window.",
                value: appleMaxTokens, range: 1...4096, step: 1, initial: 1024, integer: true
            )
        } header: {
            Text("Length")
        }
    }

    private var appleMaxTokens: Binding<Double?> {
        Binding(
            get: { options.apple.maxResponseTokens.map(Double.init) },
            set: { options.apple.maxResponseTokens = $0.map { Int($0.rounded()) } }
        )
    }

    private func reset() {
        options.apple = RunOptions.AppleOptions()
        options.openAICompatible = RunOptions.OpenAICompatibleOptions()
        stopText = ""
        stopOn = false
    }
}

// MARK: - Rows

/// Checkbox title with a hint underneath; the control is greyed out until the option is checked.
private struct OptionRow<Control: View>: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text(title)
            }
            .toggleStyle(.checkbox)
            control
                .disabled(!isOn)
                .padding(.leading, 20)
            Text(hint)
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}

/// Bounded number: slider with the range at both ends plus an editable field.
private struct SliderOption: View {
    let title: String
    let hint: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    let initial: Double
    var integer = false

    private var isOn: Binding<Bool> {
        Binding(get: { value != nil }, set: { value = $0 ? initial : nil })
    }

    private var current: Binding<Double> {
        Binding(
            get: { value ?? initial },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private var format: FloatingPointFormatStyle<Double> {
        let digits: ClosedRange<Int> = integer ? 0...0 : 0...2
        return .number.precision(.fractionLength(digits)).grouping(.never)
    }

    var body: some View {
        OptionRow(title: title, hint: hint, isOn: isOn) {
            HStack(spacing: 10) {
                Slider(value: current, in: range, step: step) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(range.lowerBound, format: format)
                        .textStyle(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(range.upperBound, format: format)
                        .textStyle(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                TextField("Value", value: current, format: format)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
            }
        }
    }
}

/// Unbounded whole number: field plus stepper.
private struct IntegerOption: View {
    let title: String
    let hint: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    let initial: Int

    private var isOn: Binding<Bool> {
        Binding(get: { value != nil }, set: { value = $0 ? initial : nil })
    }

    private var current: Binding<Int> {
        Binding(
            get: { value ?? initial },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    var body: some View {
        OptionRow(title: title, hint: hint, isOn: isOn) {
            Stepper(value: current, in: range) {
                TextField("Value", value: current, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
        }
    }
}

/// Multi-line text, e.g. stop sequences.
private struct TextOption: View {
    let title: String
    let hint: String
    let isOn: Binding<Bool>
    @Binding var text: String
    let placeholder: String

    var body: some View {
        OptionRow(title: title, hint: hint, isOn: isOn) {
            TextField(placeholder, text: $text, axis: .vertical)
                .labelsHidden()
                .lineLimit(2...5)
                .textStyle(.body, design: .monospaced)
        }
    }
}
