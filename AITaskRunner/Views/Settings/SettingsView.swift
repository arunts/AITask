import SwiftUI

enum SettingsTab: String, Hashable {
    case models
    case tools
    case general
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView(selection: $settings.settingsTab) {
            Tab("Models", systemImage: "cpu", value: SettingsTab.models) {
                ModelsSettingsView()
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver", value: SettingsTab.tools) {
                ToolsSettingsView()
            }
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 540, idealHeight: 620)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var loginItemError: String?

    private var opensAtLogin: Binding<Bool> {
        Binding(
            get: { settings.opensAtLogin },
            set: { on in
                do {
                    try settings.setOpensAtLogin(on)
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: $settings.textSize) {
                    ForEach(AppSettings.TextSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the macOS setting. Light and Dark apply to every window immediately. Text size scales all text in the app, including prompts and transcripts.")
                .textStyle(.callout)
            }
            Section {
                Toggle("Open at login", isOn: opensAtLogin)
                if settings.loginItemNeedsApproval {
                    LabeledContent {
                        Button("Open System Settings") { settings.openLoginItemsSettings() }
                    } label: {
                        Label("Turned off in System Settings › Login Items", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let loginItemError {
                    Label(loginItemError, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .textStyle(.callout)
                }
            } footer: {
                Text("Opens AITaskRunner when you log in, so scheduled tasks start without you launching it. This is the same as adding the app under System Settings › General › Login Items & Extensions, and either place can turn it off.")
                .textStyle(.callout)
            }
            Section {
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarIcon)
            } footer: {
                Text(settings.showsMenuBarIcon
                     ? "AITaskRunner stays out of the Dock. Use the menu bar icon to open the window or quit. Closing the window keeps the app running so scheduled tasks continue."
                     : "AITaskRunner appears in the Dock like any other app. Quit from the Dock icon or with ⌘Q. Closing the window keeps the app running so scheduled tasks continue.")
                .textStyle(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLoginItemStatus() }
        // The user may have changed it in System Settings; pick that up when they come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLoginItemStatus()
        }
    }
}
