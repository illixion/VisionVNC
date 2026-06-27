import SwiftUI
import SwiftTerm
import UIKit

/// SwiftTerm's `TerminalView` makes itself the first responder on tap (to show
/// its own keyboard and capture hardware keys). In VisionVNC all input is routed
/// through the composer + quick-key row, so the terminal never needs to be first
/// responder — and must not become it: on visionOS an accidental gaze-pinch on
/// the output while dictating into the composer would otherwise resign the
/// composer's first responder and abort dictation mid-sentence. Scrolling the
/// scrollback (a UIScrollView gesture) doesn't need first responder, so it's
/// unaffected.
final class DisplayOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}

/// Hosts a SwiftTerm `TerminalView` for an `SSHSession`. The view renders the
/// PTY stream and reports size changes (→ SIGWINCH) and any first-responder
/// keystrokes back to the session. Input primarily comes from the composer +
/// quick-key row in `SSHTerminalView`; this view is the display surface.
struct TerminalEmulatorView: UIViewRepresentable {
    let session: SSHSession
    var fontSize: Double = ConnectionDefaults.terminalFontSizeDefault

    func makeUIView(context: Context) -> TerminalView {
        let terminal = DisplayOnlyTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        // Opaque dark backdrop — visionOS glass washes out ANSI colors.
        let dark = UIColor(white: 0.07, alpha: 1.0)
        terminal.nativeBackgroundColor = dark
        terminal.backgroundColor = dark
        terminal.isOpaque = true
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Keep scrollback scrolling local to the view: ignore the agent's
        // mouse-mode requests so a gaze pinch-drag scrolls history instead of
        // being forwarded to the remote program as mouse events. VisionVNC
        // sends no mouse input to the agent (input is the composer + quick-key
        // row), so nothing is lost and the scrollback becomes scrollable.
        terminal.allowMouseReporting = false
        session.attach(terminal)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // SwiftTerm's font setter recomputes cell metrics, resizes the grid,
        // and re-fires sizeChanged → PTY resize — live font changes propagate
        // end-to-end with no extra plumbing.
        if uiView.font.pointSize != fontSize {
            uiView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

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
