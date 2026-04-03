import SwiftUI
@preconcurrency import MoonlightCommonC

/// Soft keyboard window for Moonlight streaming — provides typing, modifier toggles,
/// special keys, arrow keys, and function keys.
struct MoonlightKeyboardView: View {
    @Environment(MoonlightConnectionManager.self) private var manager

    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool

    // Modifier key toggle state
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false
    @State private var winActive = false

    /// Current modifier bitmask sent with every key event.
    private var modifierMask: Int8 {
        var mask: Int8 = 0
        if shiftActive { mask |= Int8(MODIFIER_SHIFT) }
        if ctrlActive  { mask |= Int8(MODIFIER_CTRL) }
        if altActive   { mask |= Int8(MODIFIER_ALT) }
        if winActive   { mask |= Int8(MODIFIER_META) }
        return mask
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Type text to send to the remote PC")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Type here…", text: $textInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onChange(of: textInput) { oldValue, newValue in
                        sendNewCharacters(old: oldValue, new: newValue)
                    }
                    .padding(.horizontal)

                // Modifier keys
                HStack(spacing: 12) {
                    modifierToggle("Ctrl", isActive: $ctrlActive, vkDown: 0xA2, vkUp: 0xA2)
                    modifierToggle("Alt", isActive: $altActive, vkDown: 0xA4, vkUp: 0xA4)
                    modifierToggle("Shift", isActive: $shiftActive, vkDown: 0xA0, vkUp: 0xA0)
                    modifierToggle("Win", isActive: $winActive, vkDown: 0x5B, vkUp: 0x5B)
                }

                // Special keys
                HStack(spacing: 12) {
                    specialKeyButton("Esc", vkCode: 0x1B)
                    specialKeyButton("Tab", vkCode: 0x09)
                    specialKeyButton("Enter", vkCode: 0x0D)
                    specialKeyButton("Bksp", vkCode: 0x08)
                    specialKeyButton("Del", vkCode: 0x2E)
                }

                // Arrow keys
                VStack(spacing: 8) {
                    specialKeyButton("↑", vkCode: 0x26)
                    HStack(spacing: 16) {
                        specialKeyButton("←", vkCode: 0x25)
                        specialKeyButton("↓", vkCode: 0x28)
                        specialKeyButton("→", vkCode: 0x27)
                    }
                }

                // Function keys
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(functionKeys, id: \.label) { fk in
                            specialKeyButton(fk.label, vkCode: fk.vkCode)
                        }
                    }
                    .padding(.horizontal)
                }

                // Ctrl+Alt+Del shortcut
                Button("Ctrl+Alt+Del") {
                    sendCtrlAltDel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Moonlight Keyboard")
            .onAppear {
                isTextFieldFocused = true
            }
            .onDisappear {
                releaseAllModifiers()
            }
        }
    }

    // MARK: - Character Sending

    private func sendNewCharacters(old: String, new: String) {
        guard new.count > old.count else { return }
        let newChars = new.suffix(new.count - old.count)
        for char in newChars {
            if char.isNewline {
                sendKeyPress(0x0D) // VK_RETURN
            } else if let vk = MoonlightKeyCodes.windowsKeyCode(for: char) {
                // Check if the character needs shift (uppercase or shifted punctuation)
                let needsShift = char.isUppercase || isShiftedPunctuation(char)
                if needsShift && !shiftActive {
                    LiSendKeyboardEvent(0xA0, Int8(KEY_ACTION_DOWN), modifierMask | Int8(MODIFIER_SHIFT))
                    LiSendKeyboardEvent(vk, Int8(KEY_ACTION_DOWN), modifierMask | Int8(MODIFIER_SHIFT))
                    LiSendKeyboardEvent(vk, Int8(KEY_ACTION_UP), modifierMask | Int8(MODIFIER_SHIFT))
                    LiSendKeyboardEvent(0xA0, Int8(KEY_ACTION_UP), modifierMask)
                } else {
                    sendKeyPress(vk)
                }
            }
        }
    }

    private func isShiftedPunctuation(_ char: Character) -> Bool {
        "!@#$%^&*()_+{}|:\"<>?~".contains(char)
    }

    // MARK: - Modifier Toggle

    private func modifierToggle(_ label: String, isActive: Binding<Bool>,
                                vkDown: Int16, vkUp: Int16) -> some View {
        Button(label) {
            isActive.wrappedValue.toggle()
            if isActive.wrappedValue {
                LiSendKeyboardEvent(vkDown, Int8(KEY_ACTION_DOWN), modifierMask)
            } else {
                LiSendKeyboardEvent(vkUp, Int8(KEY_ACTION_UP), modifierMask)
            }
        }
        .buttonStyle(.bordered)
        .tint(isActive.wrappedValue ? .accentColor : nil)
    }

    // MARK: - Special Key Button

    private func specialKeyButton(_ label: String, vkCode: Int16) -> some View {
        Button(label) {
            sendKeyPress(vkCode)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Key Press Helper

    private func sendKeyPress(_ vkCode: Int16) {
        LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_DOWN), modifierMask)
        LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_UP), modifierMask)
    }

    // MARK: - Ctrl+Alt+Del

    private func sendCtrlAltDel() {
        let ctrl: Int16 = 0xA2
        let alt: Int16 = 0xA4
        let del: Int16 = 0x2E
        let mods = Int8(MODIFIER_CTRL) | Int8(MODIFIER_ALT)

        LiSendKeyboardEvent(ctrl, Int8(KEY_ACTION_DOWN), Int8(MODIFIER_CTRL))
        LiSendKeyboardEvent(alt, Int8(KEY_ACTION_DOWN), mods)
        LiSendKeyboardEvent(del, Int8(KEY_ACTION_DOWN), mods)
        LiSendKeyboardEvent(del, Int8(KEY_ACTION_UP), mods)
        LiSendKeyboardEvent(alt, Int8(KEY_ACTION_UP), Int8(MODIFIER_CTRL))
        LiSendKeyboardEvent(ctrl, Int8(KEY_ACTION_UP), 0)
    }

    // MARK: - Function Keys

    private var functionKeys: [(label: String, vkCode: Int16)] {
        [
            ("F1", 0x70), ("F2", 0x71), ("F3", 0x72), ("F4", 0x73),
            ("F5", 0x74), ("F6", 0x75), ("F7", 0x76), ("F8", 0x77),
            ("F9", 0x78), ("F10", 0x79), ("F11", 0x7A), ("F12", 0x7B),
        ]
    }

    // MARK: - Release All Modifiers

    private func releaseAllModifiers() {
        if ctrlActive {
            LiSendKeyboardEvent(0xA2, Int8(KEY_ACTION_UP), 0)
            ctrlActive = false
        }
        if altActive {
            LiSendKeyboardEvent(0xA4, Int8(KEY_ACTION_UP), 0)
            altActive = false
        }
        if shiftActive {
            LiSendKeyboardEvent(0xA0, Int8(KEY_ACTION_UP), 0)
            shiftActive = false
        }
        if winActive {
            LiSendKeyboardEvent(0x5B, Int8(KEY_ACTION_UP), 0)
            winActive = false
        }
    }
}
