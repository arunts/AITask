import AppKit
import SwiftUI

/// Plain-text prompt editor backed by NSTextView. Highlights `server__tool` references and `{{variable}}`
/// placeholders. Tokens are inserted by clicking or dragging from the side panel (text drops are native).
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var insertion: String?
    var placeholder: String = ""
    /// Lower-cased server slugs whose tool references get highlighted (servers attached with all tools).
    var highlightPrefixes: [String] = []
    /// Lower-cased full `server__tool` names that get highlighted (explicitly selected tools).
    var highlightNames: Set<String> = []
    /// Variable keys whose `{{key}}` placeholders get highlighted.
    var highlightVariables: Set<String> = []
    var onFocus: () -> Void = {}

    @Environment(\.textScale) private var textScale

    private static let baseSize: CGFloat = 13

    static func font(scale: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: (baseSize * scale).rounded(), weight: .regular)
    }

    static func boldFont(scale: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: (baseSize * scale).rounded(), weight: .semibold)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = Self.font(scale: textScale)
        textView.textColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.placeholder = placeholder

        let coordinator = context.coordinator
        textView.onBecomeFirstResponder = { [weak coordinator] in
            coordinator?.parent.onFocus()
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        coordinator.textView = textView
        coordinator.highlightSignature = highlightSignature
        coordinator.scale = textScale
        coordinator.applyHighlighting()
        return scrollView
    }

    private var highlightSignature: String {
        highlightPrefixes.sorted().joined(separator: ",") + "|" + highlightNames.sorted().joined(separator: ",")
            + "|" + highlightVariables.sorted().joined(separator: ",")
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.placeholder = placeholder
        if context.coordinator.scale != textScale {
            context.coordinator.scale = textScale
            textView.font = Self.font(scale: textScale)
            context.coordinator.applyHighlighting()
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting()
        } else if context.coordinator.highlightSignature != highlightSignature {
            context.coordinator.highlightSignature = highlightSignature
            context.coordinator.applyHighlighting()
        }
        if let insertion {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.insertText(insertion, replacementRange: textView.selectedRange())
                self.insertion = nil
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var textView: PromptNSTextView?
        var highlightSignature = ""
        var scale: CGFloat = 1

        init(_ parent: PromptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlighting()
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            let font = PromptTextView.font(scale: scale)
            let boldFont = PromptTextView.boldFont(scale: scale)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor,
            ]
            let string = textView.string
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
            let prefixes = Set(parent.highlightPrefixes.map { $0.lowercased() })
            let names = parent.highlightNames
            if !prefixes.isEmpty || !names.isEmpty {
                for match in string.matches(of: AgentTask.toolReferencePattern)
                where prefixes.contains(String(match.1).lowercased()) || names.contains(String(match.0).lowercased()) {
                    storage.addAttributes(
                        [.foregroundColor: NSColor.controlAccentColor, .font: boldFont],
                        range: NSRange(match.range, in: string)
                    )
                }
            }
            let variables = parent.highlightVariables
            if !variables.isEmpty {
                for match in string.matches(of: AgentTask.variablePattern) where variables.contains(String(match.1)) {
                    storage.addAttributes(
                        [.foregroundColor: NSColor.systemPurple, .font: boldFont],
                        range: NSRange(match.range, in: string)
                    )
                }
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
        }
    }
}

final class PromptNSTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
