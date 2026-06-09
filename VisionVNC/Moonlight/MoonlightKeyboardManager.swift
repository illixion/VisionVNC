#if MOONLIGHT_ENABLED
import Foundation
import os
import GameController
import UIKit
@preconcurrency import MoonlightCommonC

/// Reads the hardware keyboard via the GameController framework (`GCKeyboard`)
/// and forwards keys as Moonlight events.
///
/// Why not UIKit `pressesBegan` (like the VNC path)? The Moonlight stream view
/// runs GameController (`.handlesGameControllerEvents`, `GCController`/`GCMouse`).
/// Once GameController is active, visionOS routes the hardware keyboard through
/// `GCKeyboard` and steals the UIResponder first responder, so `pressesBegan`
/// never fires there. `GCKeyboard` is the supported way to read it in that mode.
///
/// `GCKeyCode` raw values are USB HID usage IDs — identical to
/// `UIKeyboardHIDUsage` raw values — so the existing `MoonlightKeyCodes`
/// HID→Windows-VK mapping is reused directly.
@Observable
final class MoonlightKeyboardManager: @unchecked Sendable {

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Active modifier bitmask (MODIFIER_SHIFT | _CTRL | _ALT | _META), sent with
    /// every key event. Touched only from the (serial, main-queue) key handler.
    @ObservationIgnored private nonisolated(unsafe) var activeModifiers: Int8 = 0

    func startListening() {
        AppLog.gamepadManager.line("Starting keyboard listening")

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let keyboard = notification.object as? GCKeyboard else { return }
            self?.keyboardConnected(keyboard)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.activeModifiers = 0
        }

        if let keyboard = GCKeyboard.coalesced {
            keyboardConnected(keyboard)
        }
    }

    func stopListening() {
        AppLog.gamepadManager.line("Stopping keyboard listening")
        if let obs = connectObserver { NotificationCenter.default.removeObserver(obs); connectObserver = nil }
        if let obs = disconnectObserver { NotificationCenter.default.removeObserver(obs); disconnectObserver = nil }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        activeModifiers = 0
    }

    private func keyboardConnected(_ keyboard: GCKeyboard) {
        AppLog.gamepadManager.line("Keyboard connected: \(keyboard.vendorName ?? "unknown")")
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            self?.handle(keyCode: keyCode, pressed: pressed)
        }
    }

    private func handle(keyCode: GCKeyCode, pressed: Bool) {
        guard let usage = UIKeyboardHIDUsage(rawValue: keyCode.rawValue) else { return }

        let modFlag = MoonlightKeyCodes.modifierFlag(for: usage)
        // Set the modifier before sending a press; clear after sending a release
        // (matches the VNC/UIPress ordering so combos report the right state).
        if pressed && modFlag != 0 { activeModifiers |= modFlag }

        if let vkCode = MoonlightKeyCodes.windowsKeyCode(for: usage) {
            LiSendKeyboardEvent(vkCode, Int8(pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP), activeModifiers)
        }

        if !pressed && modFlag != 0 { activeModifiers &= ~modFlag }
    }
}
#endif
