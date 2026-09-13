import SwiftUI

@main
struct AITaskRunnerApp: App {
    @State private var settings: AppSettings
    @State private var store: TaskStore
    @State private var registry: MCPRegistry
    @State private var providers: ProviderHub
    @State private var scheduler: TaskScheduler

    @FocusedValue(\.taskRunner) private var focusedRunner
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    init() {
        // Writing to a dead MCP server's stdin must not take the whole app down.
        signal(SIGPIPE, SIG_IGN)
        RebrandMigration.run()
        let settings = AppSettings()
        settings.applyAppearance()
        settings.applyActivationPolicy()
        let store = TaskStore()
        // Under a unit-test host the app stays quiet: no server launches, no polling, no scheduled runs.
        let isTestHost = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
        let registry = MCPRegistry(autoConnect: !isTestHost)
        let providers = ProviderHub(settings: settings)
        // Scheduled tasks run only while the app is open; the loop lives with the app.
        let scheduler = TaskScheduler(store: store, registry: registry, settings: settings, providers: providers)
        if !isTestHost {
            providers.startPolling()
            scheduler.start()
        }
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _registry = State(initialValue: registry)
        _providers = State(initialValue: providers)
        _scheduler = State(initialValue: scheduler)
    }

    var body: some Scene {
        Window("AITaskRunner", id: "main") {
            ContentView()
                .appEnvironment(settings: settings, store: store, registry: registry, providers: providers, scheduler: scheduler)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task…") { store.beginNewTask(); openWindow(id: TaskEditorWindow.id) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Edit Task…") { store.beginEditing(id: store.selectedTaskID); openWindow(id: TaskEditorWindow.id) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.selectedTaskID == nil)
                Divider()
                Button("Import Task…") { TaskImporter.chooseFile(store: store) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Task…") {
                    if let task = store.task(id: store.selectedTaskID) {
                        TaskExporter.save(task, registry: registry)
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.selectedTaskID == nil)
                Divider()
                Button("Settings…") { openSettings() }
            }
            CommandGroup(replacing: .help) {
                Button("Task File Format") { openWindow(id: TaskFileFormatView.id) }
            }
            CommandMenu("Run") {
                Button("Stop Run") { focusedRunner?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(focusedRunner?.isActive != true)
            }
        }

        WindowGroup("Run", id: "run", for: RunRequest.self) { $request in
            if let request {
                RunWindowView(request: request)
                    .appEnvironment(settings: settings, store: store, registry: registry, providers: providers, scheduler: scheduler)
            }
        }
        .defaultSize(width: 800, height: 680)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        Window("Task Editor", id: TaskEditorWindow.id) {
            TaskEditorWindow()
                .appEnvironment(settings: settings, store: store, registry: registry, providers: providers, scheduler: scheduler)
        }
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        Window("Task File Format", id: TaskFileFormatView.id) {
            TaskFileFormatView()
                .appEnvironment(settings: settings, store: store, registry: registry, providers: providers, scheduler: scheduler)
        }
        .defaultSize(width: 840, height: 780)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        Settings {
            SettingsView()
                .appEnvironment(settings: settings, store: store, registry: registry, providers: providers, scheduler: scheduler)
        }

        // Menu bar mode: the app has no Dock icon, so this is how the user gets back in or quits.
        // Closing the last window keeps the app, and any schedule, running in both modes.
        MenuBarExtra("AITaskRunner", systemImage: "checklist", isInserted: $settings.showsMenuBarIcon) {
            Button("Open AITaskRunner") {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
            Divider()
            Button("Quit AITaskRunner") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
