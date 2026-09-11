import AppKit
import SwiftUI

/// Routes the window's close button and ⌘W to `onClose` instead of closing the window outright.
/// The handler decides what happens (confirm, discard, dismiss); the window stays open until then.
/// Every other delegate call is forwarded to the delegate SwiftUI installed, so the scene keeps working.
struct WindowCloseInterceptor: NSViewRepresentable {
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        let coordinator = context.coordinator
        view.onAttach = { window in coordinator.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        context.coordinator.onClose = onClose
    }

    static func dismantleNSView(_ nsView: AccessorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AccessorView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var onClose: () -> Void = {}
        private weak var window: NSWindow?
        nonisolated(unsafe) private weak var original: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            original = window.delegate
            window.delegate = self
        }

        func detach() {
            if let window, window.delegate === self { window.delegate = original }
            window = nil
            original = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            onClose()
            return false
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            original
        }
    }
}
