import Foundation
import Observation

/// Aggregates every model source so pickers and status indicators have one place to look.
@Observable
final class ProviderHub {
    enum EndpointStatus: Equatable {
        case unknown
        case checking
        case online
        case offline(String)
        /// Turned off in Settings; kept configured but not polled.
        case disabled
        /// No base URL entered yet.
        case notConfigured

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking…"
            case .online: return "Online"
            case .offline(let reason): return "Offline — \(reason)"
            case .disabled: return "Turned off"
            case .notConfigured: return "Enter a base URL"
            }
        }
    }

    let settings: AppSettings
    let foundation = FoundationModelProvider()

    /// Last poll result per endpoint. Endpoints that are off or unconfigured have no entry.
    private var endpointStatuses: [UUID: EndpointStatus] = [:]
    private var endpointModels: [UUID: [String]] = [:]
    /// Discovered window sizes, keyed by `ModelChoice.rawValue`.
    private var discoveredWindows: [String: (tokens: Int, source: String)] = [:]
    /// What endpoints reported (and runs found out) about each model, keyed by `ModelChoice.rawValue`.
    private var discoveredCapabilities: [String: CapabilityReport] = [:]
    /// Models asked about at least once this session, so endpoints that never answer are not asked on every poll.
    private var capabilityProbes: Set<String> = []
    private var pollingTask: Task<Void, Never>?

    /// Apple's on-device model: tools through the framework, no images, no reasoning trace.
    static let appleCapabilities = CapabilityReport(supported: [.tools], unsupported: [.vision, .thinking], source: "Apple")

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Keeps the status indicators live for the whole app session. Safe to call again; it restarts the loop.
    func startPolling(every interval: Duration = .seconds(30)) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - Endpoints

    func status(for endpointID: UUID) -> EndpointStatus {
        guard let endpoint = settings.endpoint(id: endpointID) else { return .unknown }
        if !endpoint.isEnabled { return .disabled }
        if !endpoint.isConfigured { return .notConfigured }
        return endpointStatuses[endpointID] ?? .unknown
    }

    /// Models the endpoint listed, or nothing while it is off, unconfigured or unreachable.
    func models(for endpointID: UUID) -> [String] {
        status(for: endpointID) == .online ? endpointModels[endpointID] ?? [] : []
    }

    /// Client for an endpoint that exists, is turned on and has a usable base URL.
    func client(for endpointID: UUID) throws -> OpenAICompatibleClient {
        guard let endpoint = settings.endpoint(id: endpointID) else { throw OpenAICompatibleError.endpointMissing }
        guard endpoint.isEnabled else { throw OpenAICompatibleError.endpointDisabled(endpoint.displayName) }
        guard let client = OpenAICompatibleClient(baseURLString: endpoint.baseURL, apiKey: endpoint.apiKey) else {
            throw OpenAICompatibleError.invalidBaseURL(endpoint.displayName)
        }
        return client
    }

    /// Every model the user can pick right now: Apple's model first, then each endpoint's models in Settings order.
    var choices: [ModelChoice] {
        (foundation.isAvailable ? [.appleFoundation] : []) + settings.endpoints.flatMap { endpoint in
            models(for: endpoint.id).map { ModelChoice.openAICompatible(endpointID: endpoint.id, model: $0) }
        }
    }

    // MARK: - Context windows

    /// Context window for an endpoint model: the user's override, else whatever the server reports (cached).
    func contextWindow(for choice: ModelChoice) async -> (tokens: Int, source: String)? {
        guard case .openAICompatible(let endpointID, let model) = choice else { return nil }
        if let known = knownContextWindow(for: choice) { return known }
        guard let client = try? client(for: endpointID), let found = await client.discoverContextWindow(model: model) else { return nil }
        discoveredWindows[choice.rawValue] = found
        return found
    }

    /// Last discovered window without asking the server again.
    func knownContextWindow(for choice: ModelChoice) -> (tokens: Int, source: String)? {
        if let manual = settings.contextWindows[choice.rawValue] { return (manual, "set by you") }
        return discoveredWindows[choice.rawValue]
    }

    // MARK: - Capabilities

    /// What is known right now about a model, without asking the server: the endpoint's report and anything
    /// runs found out. Unknown until the model has been looked up.
    func knownCapabilities(for choice: ModelChoice) -> CapabilityReport {
        switch choice {
        case .appleFoundation:
            return Self.appleCapabilities
        case .openAICompatible:
            return discoveredCapabilities[choice.rawValue] ?? .unknown
        }
    }

    /// Like `knownCapabilities`, but asks the endpoint first when nothing has been discovered yet.
    func capabilities(for choice: ModelChoice) async -> CapabilityReport {
        if case .openAICompatible(let endpointID, let model) = choice, discoveredCapabilities[choice.rawValue] == nil {
            await lookUpCapabilities(endpointID: endpointID, model: model)
        }
        return knownCapabilities(for: choice)
    }

    /// Records what a run found out, e.g. the server refused images or the model called a tool.
    /// A run's evidence outranks the endpoint's report for that capability.
    func learn(_ capability: ModelCapability, supported: Bool, for choice: ModelChoice) {
        guard case .openAICompatible = choice else { return }
        var report = discoveredCapabilities[choice.rawValue] ?? .unknown
        report.set(capability, supported: supported, source: "a run")
        discoveredCapabilities[choice.rawValue] = report
    }

    private func lookUpCapabilities(endpointID: UUID, model: String) async {
        let key = ModelChoice.openAICompatible(endpointID: endpointID, model: model).rawValue
        capabilityProbes.insert(key)
        guard let client = try? client(for: endpointID), let found = await client.discoverCapabilities(model: model) else { return }
        // The endpoint may have been removed, or a run may have learned something, while the request was in flight.
        guard settings.endpoint(id: endpointID) != nil else { return }
        var report = found
        for (capability, entry) in discoveredCapabilities[key]?.entries ?? [:] where entry.source == "a run" {
            report.entries[capability] = entry
        }
        discoveredCapabilities[key] = report
    }

    /// Asks about every listed model that has not been asked about this session, all at once.
    private func discoverCapabilities(endpointID: UUID, models: [String]) async {
        let pending = models.filter { model in
            let key = ModelChoice.openAICompatible(endpointID: endpointID, model: model).rawValue
            return discoveredCapabilities[key] == nil && !capabilityProbes.contains(key)
        }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for model in pending {
                group.addTask { await self.lookUpCapabilities(endpointID: endpointID, model: model) }
            }
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        foundation.refresh()
        await refreshEndpoints()
    }

    /// Polls every endpoint that is on and configured, all at once, and forgets results for endpoints that were removed.
    func refreshEndpoints() async {
        let endpoints = settings.endpoints
        let keep = Set(endpoints.map(\.id))
        endpointStatuses = endpointStatuses.filter { keep.contains($0.key) }
        endpointModels = endpointModels.filter { keep.contains($0.key) }
        discoveredCapabilities = discoveredCapabilities.filter { entry in
            guard let id = ModelChoice(rawValue: entry.key)?.endpointID else { return true }
            return keep.contains(id)
        }

        let active = endpoints.filter { $0.isEnabled && $0.isConfigured }
        for endpoint in active where endpointStatuses[endpoint.id] != .online {
            endpointStatuses[endpoint.id] = .checking
        }

        let results = await withTaskGroup(of: (UUID, Result<[String], any Error>).self) { group in
            for endpoint in active {
                guard let client = OpenAICompatibleClient(baseURLString: endpoint.baseURL, apiKey: endpoint.apiKey) else {
                    endpointStatuses[endpoint.id] = .offline("invalid URL")
                    endpointModels[endpoint.id] = []
                    continue
                }
                group.addTask {
                    do {
                        return (endpoint.id, .success(try await client.listModels()))
                    } catch {
                        return (endpoint.id, .failure(error))
                    }
                }
            }
            var collected: [UUID: Result<[String], any Error>] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }

        for (id, result) in results {
            // The endpoint may have been removed while its request was in flight.
            guard settings.endpoint(id: id) != nil else { continue }
            switch result {
            case .success(let models):
                endpointModels[id] = models
                endpointStatuses[id] = .online
                Task { await discoverCapabilities(endpointID: id, models: models) }
            case .failure(let error):
                endpointModels[id] = []
                endpointStatuses[id] = .offline(Self.shortReason(for: error))
            }
        }
    }

    private static func shortReason(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost: return "nothing is listening at that address"
            case .timedOut: return "timed out"
            case .cannotFindHost: return "host not found"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
