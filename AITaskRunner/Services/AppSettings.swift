import AppKit
import Foundation
import Observation
import ServiceManagement

/// UserDefaults-backed settings. Only endpoint configuration lives here; no run history is ever stored.
@Observable
final class AppSettings {
    fileprivate enum Keys {
        static let endpoints = "endpoints"
        /// Written before multiple endpoints existed; read once to migrate into `endpoints`.
        static let legacyBaseURL = "local.baseURL"
        static let legacyAPIKey = "local.apiKey"
        static let defaultModel = "run.defaultModel"
        static let appearance = "ui.appearance"
        static let contextWindows = "local.contextWindows"
        static let textSize = "ui.textSize"
        static let menuBarIcon = "ui.menuBarIcon"
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        /// `nil` means follow the system setting.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Multiplier applied to every font in the app. macOS ignores the system Dynamic Type setting, so this is ours.
    enum TextSize: String, CaseIterable, Identifiable {
        case small
        case standard
        case large
        case extraLarge

        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return "Small"
            case .standard: return "Default"
            case .large: return "Large"
            case .extraLarge: return "Extra Large"
            }
        }

        var scale: CGFloat {
            switch self {
            case .small: return 0.92
            case .standard: return 1.0
            case .large: return 1.15
            case .extraLarge: return 1.3
            }
        }
    }

    private let defaults = UserDefaults.standard

    /// Which Settings tab is showing. Not persisted; the sidebar footer sets it before opening Settings.
    var settingsTab: SettingsTab = .models

    /// Every OpenAI-compatible endpoint the user has added, in the order they appear in Settings and pickers.
    var endpoints: [OpenAICompatibleEndpoint] {
        didSet { saveEndpoints() }
    }

    var defaultModel: String {
        didSet { defaults.set(defaultModel, forKey: Keys.defaultModel) }
    }

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Context window sizes the user typed in, keyed by `ModelChoice.rawValue`. Override anything discovered.
    var contextWindows: [String: Int] {
        didSet { defaults.set(contextWindows, forKey: Keys.contextWindows) }
    }

    var textSize: TextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Keys.textSize) }
    }

    /// On: the app lives in the menu bar and stays out of the Dock. Off: a normal Dock app.
    var showsMenuBarIcon: Bool {
        didSet {
            defaults.set(showsMenuBarIcon, forKey: Keys.menuBarIcon)
            applyActivationPolicy()
        }
    }

    init() {
        if let data = defaults.data(forKey: Keys.endpoints),
           let saved = try? JSONDecoder().decode([OpenAICompatibleEndpoint].self, from: data) {
            endpoints = saved
        } else {
            endpoints = [Self.migratedEndpoint(from: defaults)]
        }
        defaultModel = ModelChoice.canonical(defaults.string(forKey: Keys.defaultModel) ?? "")
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        contextWindows = Self.migratedContextWindows(defaults.dictionary(forKey: Keys.contextWindows) as? [String: Int] ?? [:])
        textSize = TextSize(rawValue: defaults.string(forKey: Keys.textSize) ?? "") ?? .standard
        showsMenuBarIcon = defaults.object(forKey: Keys.menuBarIcon) as? Bool ?? true
    }

    // MARK: - Endpoints

    /// The endpoint saved under the single-endpoint keys, or the first preset on a fresh install.
    private static func migratedEndpoint(from defaults: UserDefaults) -> OpenAICompatibleEndpoint {
        let url = defaults.string(forKey: Keys.legacyBaseURL) ?? OpenAICompatibleEndpoint.presets[0].url
        let preset = OpenAICompatibleEndpoint.presets.first { $0.url.lowercased() == url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return OpenAICompatibleEndpoint(
            id: ModelChoice.legacyEndpointID,
            name: preset?.name ?? "Endpoint 1",
            baseURL: url,
            apiKey: defaults.string(forKey: Keys.legacyAPIKey) ?? ""
        )
    }

    /// Window sizes were keyed by bare model id before endpoints were namespaced; those belong to the migrated endpoint.
    private static func migratedContextWindows(_ stored: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, value) in stored {
            let canonical = key.hasPrefix(ModelChoice.endpointPrefix)
                ? key
                : ModelChoice.openAICompatible(endpointID: ModelChoice.legacyEndpointID, model: key).rawValue
            result[canonical] = value
        }
        return result
    }

    private func saveEndpoints() {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        defaults.set(data, forKey: Keys.endpoints)
    }

    func endpoint(id: UUID) -> OpenAICompatibleEndpoint? {
        endpoints.first { $0.id == id }
    }

    /// Adds an endpoint for the first preset not already in use, or a blank one when every preset is taken.
    @discardableResult
    func addEndpoint() -> OpenAICompatibleEndpoint {
        let usedURLs = Set(endpoints.map { $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let preset = OpenAICompatibleEndpoint.presets.first { !usedURLs.contains($0.url.lowercased()) }
        let endpoint = OpenAICompatibleEndpoint(name: preset?.name ?? "New Endpoint", baseURL: preset?.url ?? "")
        endpoints.append(endpoint)
        return endpoint
    }

    /// Removes the endpoint and the window sizes typed in for its models. Tasks keep their model reference and report it as unavailable.
    func removeEndpoint(id: UUID) {
        endpoints.removeAll { $0.id == id }
        contextWindows = contextWindows.filter { ModelChoice(rawValue: $0.key)?.endpointID != id }
    }

    /// The model with its endpoint namespace, e.g. "Ollama › qwen3:8b". Falls back to the bare model when the endpoint is gone.
    func displayName(for choice: ModelChoice) -> String {
        switch choice {
        case .appleFoundation:
            return choice.displayName
        case .openAICompatible(let endpointID, let model):
            guard let endpoint = endpoint(id: endpointID) else { return model }
            return "\(endpoint.displayName) › \(model)"
        }
    }

    // MARK: - Open at login

    /// Mirrors the system's Login Items list rather than UserDefaults, so it cannot drift from
    /// what System Settings shows. Refresh it whenever the app comes to the front.
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered

    /// Registered, whether or not the user has approved it in System Settings yet.
    var opensAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    /// The user turned the item off (or has not yet allowed it) in System Settings › Login Items.
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Same effect as adding or removing the app under System Settings › General › Login Items & Extensions.
    func setOpensAtLogin(_ on: Bool) throws {
        defer { refreshLoginItemStatus() }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Applies the chosen appearance to every window of the app.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// Hides the app from the Dock in menu bar mode, shows it otherwise. The bundle launches as an
    /// accessory (`LSUIElement`), so it never flashes in the Dock before this runs; that also means the
    /// system does not activate it on launch, which is why the app activates itself here.
    func applyActivationPolicy() {
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = showsMenuBarIcon ? .accessory : .regular
        if app.activationPolicy() != policy {
            app.setActivationPolicy(policy)
        }
        // Deferred so the windows exist at launch; after a policy change it also restores the menu bar.
        DispatchQueue.main.async { app.activate() }
    }
}

/// Where task and server definitions are stored.
nonisolated enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AITaskRunner", directoryHint: .isDirectory)
    }
}

/// One-time carry-over from when the app was called OddJobs: settings lived under the old bundle
/// identifier and files under Application Support/OddJobs. Runs before anything reads either place and
/// does nothing once the new locations hold data. Delete before the first public release.
nonisolated enum RebrandMigration {
    private static let legacyBundleID = "ArunThotta.OddJobs"
    private static let legacyFolderName = "OddJobs"

    static func run() {
        let fileManager = FileManager.default
        let folder = AppPaths.supportDirectory
        let legacyFolder = folder.deletingLastPathComponent().appending(path: legacyFolderName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: folder.path), fileManager.fileExists(atPath: legacyFolder.path) {
            try? fileManager.moveItem(at: legacyFolder, to: folder)
        }

        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettings.Keys.endpoints) == nil,
           defaults.object(forKey: AppSettings.Keys.legacyBaseURL) == nil,
           let legacy = defaults.persistentDomain(forName: legacyBundleID) {
            for (key, value) in legacy { defaults.set(value, forKey: key) }
        }
    }
}

/// Debounced JSON persistence shared by the task and server stores.
nonisolated enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable & Sendable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("AITaskRunner: failed to save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
