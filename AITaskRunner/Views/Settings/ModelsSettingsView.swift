import SwiftUI

struct ModelsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderHub.self) private var providers

    @State private var refreshTask: Task<Void, Never>?
    @State private var showAppleDetails = false
    @State private var pendingRemoval: OpenAICompatibleEndpoint?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Status") {
                    StatusLabel(providers.foundation.statusLabel, tone: providers.foundation.isAvailable ? .good : .bad)
                }
                DisclosureGroup("Details", isExpanded: $showAppleDetails) {
                    LabeledContent("Current locale") {
                        Text(providers.foundation.supportsCurrentLocale
                             ? "Supported (\(Locale.current.identifier))"
                             : "Not supported (\(Locale.current.identifier))")
                    }
                    LabeledContent("Languages (\(providers.foundation.supportedLanguages.count))") {
                        Text(providers.foundation.supportedLanguages.isEmpty ? "—" : providers.foundation.supportedLanguages.joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Apple Foundation Model")
            } footer: {
                Text(providers.foundation.statusDetail ?? "Reported live by the FoundationModels framework on this Mac.")
                .textStyle(.callout)
            }

            ForEach($settings.endpoints) { $endpoint in
                EndpointSection(
                    endpoint: $endpoint,
                    status: providers.status(for: endpoint.id),
                    models: providers.models(for: endpoint.id),
                    remove: { pendingRemoval = endpoint }
                )
            }

            Section {
                Button {
                    settings.addEndpoint()
                } label: {
                    Label("Add Endpoint", systemImage: "plus")
                }
            } footer: {
                Text("Any OpenAI-compatible server: LM Studio, Ollama, llama.cpp, vLLM and others that serve /v1/models and /v1/chat/completions. Models are listed under the endpoint they come from, so two endpoints may serve a model with the same name. Status refreshes on its own. Next to each model is what its server says it can do (tool calling, vision, thinking); tasks that need one of those are only run on models that have it.")
                .textStyle(.callout)
            }

            Section {
                Picker("Model for new tasks", selection: $settings.defaultModel) {
                    ModelPickerOptions(choices: providers.choices, unavailable: settings.defaultModel, noneTitle: "First available")
                }
                if !settings.contextWindows.isEmpty {
                    let rows = settings.contextWindows.keys
                        .map { key in (key: key, name: ModelChoice(rawValue: key).map { settings.displayName(for: $0) } ?? key) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    ForEach(rows, id: \.key) { row in
                        LabeledContent(row.name) {
                            HStack(spacing: 10) {
                                Text("\(settings.contextWindows[row.key, default: 0].formatted()) tokens")
                                    .monospacedDigit()
                                Button {
                                    settings.contextWindows[row.key] = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Forget this window size and use what the server reports")
                            }
                        }
                        .textStyle(.body, design: .monospaced)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text(settings.contextWindows.isEmpty
                     ? "Tasks remember the model they last ran with; this one is used until then."
                     : "Tasks remember the model they last ran with; this one is used until then. The context window sizes listed were set by you for models whose server does not report one.")
                .textStyle(.callout)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.endpoints) {
            refreshTask?.cancel()
            refreshTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                await providers.refreshEndpoints()
            }
        }
        .task { await providers.refreshAll() }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { endpoint in
            Button("Remove", role: .destructive) {
                settings.removeEndpoint(id: endpoint.id)
            }
        } message: { _ in
            Text("Tasks that chose a model from this endpoint keep their reference and will report it as unavailable. Turn the endpoint off instead to keep its settings.")
        }
    }
}

/// One endpoint's settings: name, address, key, on/off switch and what it is serving right now.
private struct EndpointSection: View {
    @Binding var endpoint: OpenAICompatibleEndpoint
    let status: ProviderHub.EndpointStatus
    let models: [String]
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $endpoint.name, prompt: Text("Ollama"))
                    .labelsHidden()
            }
            LabeledContent("Base URL") {
                HStack(spacing: 8) {
                    TextField("Base URL", text: $endpoint.baseURL, prompt: Text("http://localhost:1234/v1"))
                        .labelsHidden()
                    Menu {
                        ForEach(OpenAICompatibleEndpoint.presets) { preset in
                            Button {
                                apply(preset)
                            } label: {
                                if endpoint.matchingPreset?.id == preset.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    } label: {
                        Text(endpoint.matchingPreset?.name ?? "Presets")
                    }
                    .fixedSize()
                }
            }
            LabeledContent("API key") {
                SecureField("API key", text: $endpoint.apiKey, prompt: Text("Optional"))
                    .labelsHidden()
            }
            Toggle("Enabled", isOn: $endpoint.isEnabled)
            LabeledContent("Status") {
                StatusLabel(status.label, tone: status.tone)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if !models.isEmpty {
                LabeledContent("Models (\(models.count))") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(models, id: \.self) { model in
                            ModelCapabilitiesRow(choice: .openAICompatible(endpointID: endpoint.id, model: model))
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(endpoint.displayName)
                Spacer()
                Button("Remove…", action: remove)
                    .buttonStyle(.borderless)
                    .textStyle(.callout)
            }
        }
    }

    /// Fills in the preset's address, and its name too unless the user typed their own.
    private func apply(_ preset: OpenAICompatibleEndpoint.Preset) {
        let trimmed = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAutoName = trimmed.isEmpty || trimmed == "New Endpoint" || OpenAICompatibleEndpoint.presets.contains { $0.name == trimmed }
        endpoint.baseURL = preset.url
        if isAutoName { endpoint.name = preset.name }
    }
}
