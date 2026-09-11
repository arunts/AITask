import SwiftUI

// MARK: - Status

/// Semantic state shared by every status indicator in the app.
/// The symbol changes with the tone so colour is never the only cue.
enum StatusTone {
    case neutral
    case pending
    case good
    case warning
    case bad

    var symbol: String {
        switch self {
        case .neutral: return "circle"
        case .pending: return "circle.dotted"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .pending: return .orange
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}

/// Symbol-only marker for rows whose text already says what the state is.
struct StatusIcon: View {
    let tone: StatusTone

    var body: some View {
        Image(systemName: tone.symbol)
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }
}

/// Symbol plus text, for status rows in forms and toolbars.
struct StatusLabel: View {
    let title: String
    let tone: StatusTone

    init(_ title: String, tone: StatusTone) {
        self.title = title
        self.tone = tone
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.color)
        }
    }
}

extension MCPRegistry.State {
    var tone: StatusTone {
        switch self {
        case .disconnected: return .neutral
        case .connecting: return .pending
        case .connected: return .good
        case .failed: return .bad
        }
    }
}

extension ProviderHub.EndpointStatus {
    var tone: StatusTone {
        switch self {
        case .unknown: return .neutral
        case .checking: return .pending
        case .online: return .good
        case .offline: return .bad
        case .disabled, .notConfigured: return .neutral
        }
    }
}

extension TaskRunner.Status {
    /// Nil while the run is active (a spinner is shown instead).
    var tone: StatusTone? {
        switch self {
        case .preparing, .running, .waitingForInput, .waitingForApproval: return nil
        case .idle, .finished: return .good
        case .failed: return .bad
        case .stopped: return .warning
        }
    }
}

// MARK: - Context gauge

/// Shared formatting and thresholds for "how full is the context" figures.
enum ContextGauge {
    static func fraction(used: Int, of budget: Int?) -> Double? {
        guard let budget, budget > 0 else { return nil }
        return min(1, Double(used) / Double(budget))
    }

    /// Accent (or `base`) until 80 %, orange until 95 %, then red.
    static func tint(used: Int, of budget: Int?, base: Color = .accentColor) -> Color {
        guard let fraction = fraction(used: used, of: budget) else { return base }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.8 { return .orange }
        return base
    }

    /// "1,234 of 16,384 tokens" or "1,234 tokens". With `percent`, "1,234 of 16,384 tokens (8%)".
    static func text(used: Int, window: Int?, percent: Bool = false) -> String {
        guard let window else { return "\(used.formatted()) tokens" }
        var text = "\(used.formatted()) of \(window.formatted()) tokens"
        if percent, let fraction = fraction(used: used, of: window) {
            let rounded = Int((fraction * 100).rounded())
            text += rounded == 0 && used > 0 ? " (<1%)" : " (\(rounded)%)"
        }
        return text
    }

    /// "1.2K / 16K" or "1.2K".
    static func compactText(used: Int, window: Int?) -> String {
        if let window { return "\(compact(used)) / \(compact(window))" }
        return compact(used)
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

/// Toolbar-sized context readout: gauge symbol plus "1.2K / 16K", tinted as it fills.
struct ContextUsageLabel: View {
    var used: Int
    var window: Int?
    var budget: Int?

    var body: some View {
        Label(ContextGauge.compactText(used: used, window: window), systemImage: "gauge.with.dots.needle.33percent")
            .monospacedDigit()
            .foregroundStyle(ContextGauge.tint(used: used, of: budget, base: .secondary))
    }
}

// MARK: - Model picker

/// Options for every model picker: Apple first, then one group per endpoint so same-named models stay apart.
/// `unavailable` is a remembered choice that is not offered right now; it stays selectable so it is not silently replaced.
struct ModelPickerOptions: View {
    @Environment(AppSettings.self) private var settings

    let choices: [ModelChoice]
    var unavailable: String? = nil
    var noneTitle: String? = nil

    var body: some View {
        if let noneTitle {
            Text(noneTitle).tag("")
        }
        if choices.isEmpty {
            Text("No models available").tag(unavailable ?? "")
        }
        if let unavailable, !unavailable.isEmpty, !choices.contains(where: { $0.rawValue == unavailable }) {
            let name = ModelChoice(rawValue: unavailable).map { settings.displayName(for: $0) } ?? unavailable
            Text("\(name) (unavailable)").tag(unavailable)
        }
        let apple = choices.filter(\.isApple)
        if !apple.isEmpty {
            Section("Apple") {
                ForEach(apple, id: \.rawValue) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
        }
        ForEach(settings.endpoints) { endpoint in
            let models = choices.filter { $0.endpointID == endpoint.id }
            if !models.isEmpty {
                Section(endpoint.displayName) {
                    ForEach(models, id: \.rawValue) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
            }
        }
    }
}

// MARK: - Text helpers

extension Int {
    /// "1 tool" / "3 tools".
    func counted(_ singular: String, plural: String? = nil) -> String {
        "\(formatted()) \(self == 1 ? singular : (plural ?? singular + "s"))"
    }
}

extension AgentTask {
    /// First non-empty line of the user prompt, for list rows and previews.
    var promptPreview: String {
        userPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
    }

    /// Short descriptor such as "3 tools · 2 variables · Interactive".
    /// Pass the callable tool count when a registry is at hand; otherwise tools are listed without a number.
    func traits(toolCount: Int? = nil) -> String {
        var parts: [String] = []
        if usesTools {
            if let toolCount, toolCount > 0 {
                parts.append(toolCount.counted("tool"))
            } else {
                parts.append("Tools")
            }
        }
        if !variables.isEmpty { parts.append(variables.count.counted("variable")) }
        if allowsSteering { parts.append("Interactive") }
        return parts.isEmpty ? "Prompt only" : parts.joined(separator: " · ")
    }
}

// MARK: - Text size

extension EnvironmentValues {
    /// Multiplier for every font in the app; set once per scene from the Text Size setting.
    @Entry var textScale: CGFloat = 1
}

extension Font {
    /// macOS point sizes of the system text styles (they do not follow Dynamic Type on the Mac).
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    /// A system text style at the given scale, keeping the style's usual weight unless one is passed.
    static func scaled(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil, scale: CGFloat) -> Font {
        let resolvedWeight = weight ?? (style == .headline ? .bold : .regular)
        return .system(size: (baseSize(style) * scale).rounded(), weight: resolvedWeight, design: design)
    }
}

private struct ScaledTextStyle: ViewModifier {
    let style: Font.TextStyle
    let design: Font.Design
    let weight: Font.Weight?

    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.font(.scaled(style, design: design, weight: weight, scale: scale))
    }
}

extension View {
    /// Use instead of `.font(.caption)` and friends so the Text Size setting applies.
    func textStyle(_ style: Font.TextStyle, design: Font.Design = .default, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledTextStyle(style: style, design: design, weight: weight))
    }
}

// MARK: - Grouped sections outside a Form

/// A grouped-Form-style section that stretches to the available width. Form's grouped style stops at a
/// fixed column width, which leaves wide windows mostly empty; this keeps the header, rounded box and
/// footer but fills the window. Give each row `.groupedRow()` and put a `Divider()` between rows.
struct GroupedSection<Header: View, Content: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let header: Header
    private let content: Content
    private let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    private var fill: AnyShapeStyle {
        colorScheme == .dark ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
                .textStyle(.body, weight: .semibold)
                .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
            footer
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
        .labeledContentStyle(GroupedRowLabeledContentStyle())
    }
}

extension GroupedSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension GroupedSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { Text(title) }, footer: footer)
    }
}

/// Label leading, content trailing, the way Form lays out `LabeledContent`.
private struct GroupedRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
                .multilineTextAlignment(.trailing)
        }
    }
}

extension View {
    /// Padding for one row inside a `GroupedSection`.
    func groupedRow() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - App plumbing

extension View {
    /// Injects the app-wide stores once, for every scene, and applies the Text Size setting.
    func appEnvironment(settings: AppSettings, store: TaskStore, registry: MCPRegistry, providers: ProviderHub, scheduler: TaskScheduler) -> some View {
        let scale = settings.textSize.scale
        // At the default size leave every control on its own system font; otherwise scale the base font too.
        return font(scale == 1 ? nil : .scaled(.body, scale: scale))
            .environment(\.textScale, scale)
            .environment(settings)
            .environment(store)
            .environment(registry)
            .environment(providers)
            .environment(scheduler)
    }
}

extension FocusedValues {
    /// The runner of the frontmost run window, so menu commands can reach it.
    @Entry var taskRunner: TaskRunner?
}
