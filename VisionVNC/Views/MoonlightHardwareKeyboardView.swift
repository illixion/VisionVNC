import SwiftUI
import UIKit
@preconcurrency import MoonlightCommonC

/// A UIViewRepresentable that captures hardware/Bluetooth keyboard events
/// and forwards them as Moonlight keyboard events via LiSendKeyboardEvent().
struct MoonlightHardwareKeyboardView: UIViewRepresentable {

    func makeUIView(context: Context) -> MoonlightKeyCaptureView {
        let view = MoonlightKeyCaptureView()
        return view
    }

    func updateUIView(_ uiView: MoonlightKeyCaptureView, context: Context) {}
}

/// A UIView that becomes first responder to intercept hardware keyboard press events.
final class MoonlightKeyCaptureView: UIView {

    /// Tracks active modifier state as a bitmask (MODIFIER_SHIFT | MODIFIER_CTRL | MODIFIER_ALT | MODIFIER_META).
    private var activeModifiers: Int8 = 0

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        }
    }

    // MARK: - Press Events

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode

            // Update modifier state if this is a modifier key
            let modFlag = MoonlightKeyCodes.modifierFlag(for: usage)
            if modFlag != 0 {
                activeModifiers |= modFlag
            }

            // Map HID usage to Windows VK code
            if let vkCode = MoonlightKeyCodes.windowsKeyCode(for: usage) {
                LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_DOWN), activeModifiers)
                handled = true
            } else {
                // Try character-based mapping for printable keys
                let chars = key.charactersIgnoringModifiers
                if let char = chars.first,
                   let vkCode = MoonlightKeyCodes.windowsKeyCode(for: char) {
                    LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_DOWN), activeModifiers)
                    handled = true
                }
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode

            // Map HID usage to Windows VK code
            if let vkCode = MoonlightKeyCodes.windowsKeyCode(for: usage) {
                LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_UP), activeModifiers)
                handled = true
            } else {
                let chars = key.charactersIgnoringModifiers
                if let char = chars.first,
                   let vkCode = MoonlightKeyCodes.windowsKeyCode(for: char) {
                    LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_UP), activeModifiers)
                    handled = true
                }
            }

            // Update modifier state after sending the key up
            let modFlag = MoonlightKeyCodes.modifierFlag(for: usage)
            if modFlag != 0 {
                activeModifiers &= ~modFlag
            }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancellation as key up to avoid stuck keys
        pressesEnded(presses, with: event)
    }
}
