import SwiftUI
import SwiftTerm
import UIKit

/// Hosts a SwiftTerm `TerminalView` for an `SSHSession`. The view renders the
/// PTY stream and reports size changes (→ SIGWINCH) and any first-responder
/// keystrokes back to the session. Input primarily comes from the composer +
/// quick-key row in `SSHTerminalView`; this view is the display surface.
struct TerminalEmulatorView: UIViewRepresentable {
    let session: SSHSession

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        // Opaque dark backdrop — visionOS glass washes out ANSI colors.
        let dark = UIColor(white: 0.07, alpha: 1.0)
        terminal.nativeBackgroundColor = dark
        terminal.backgroundColor = dark
        terminal.isOpaque = true
        session.attach(terminal)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// SwiftTerm delegate. `TerminalViewDelegate` is not `@MainActor`, but
    /// SwiftTerm always invokes it on the main thread, so we assume isolation
    /// to reach the MainActor `SSHSession` without an async hop (preserving
    /// keystroke ordering).
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: SSHSession
        init(session: SSHSession) { self.session = session }

        func detach() { MainActor.assumeIsolated { session.detach() } }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.sendBytes(Array(data)) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
