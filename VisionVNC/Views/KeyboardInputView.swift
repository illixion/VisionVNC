import SwiftUI
import RoyalVNCKit

struct KeyboardInputView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool

    // Modifier key toggle state
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false
    @State private var cmdActive = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Type text to send to the remote desktop")
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
                modifierToggle("Ctrl", isActive: $ctrlActive, keyDown: .control, keyUp: .control)
                modifierToggle("Alt", isActive: $altActive, keyDown: .option, keyUp: .option)
                modifierToggle("Shift", isActive: $shiftActive, keyDown: .shift, keyUp: .shift)
                modifierToggle("Cmd", isActive: $cmdActive, keyDown: .command, keyUp: .command)
            }

            // Special keys
            HStack(spacing: 12) {
                specialKeyButton("Esc", keyCode: .escape)
                specialKeyButton("Tab", keyCode: .tab)
                specialKeyButton("Enter", keyCode: .return)
                specialKeyButton("Del", keyCode: .delete)
            }

            // Arrow keys
            VStack(spacing: 8) {
                specialKeyButton("↑", keyCode: .upArrow)
                HStack(spacing: 16) {
                    specialKeyButton("←", keyCode: .leftArrow)
                    specialKeyButton("↓", keyCode: .downArrow)
                    specialKeyButton("→", keyCode: .rightArrow)
                }
            }

            // Function keys
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(functionKeys, id: \.label) { fk in
                        specialKeyButton(fk.label, keyCode: fk.keyCode)
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
        .navigationTitle("Keyboard")
        .onAppear {
            isTextFieldFocused = true
        }
        .onDisappear {
            releaseAllModifiers()
        }
    }

    // MARK: - Character Sending

    private func sendNewCharacters(old: String, new: String) {
        guard new.count > old.count else { return }
        let newChars = new.suffix(new.count - old.count)
        for char in newChars {
            if char.isNewline {
                connectionManager.sendKeyDown(.return)
                connectionManager.sendKeyUp(.return)
            } else {
                let keyCodes = VNCKeyCode.withCharacter(char)
                for keyCode in keyCodes {
                    connectionManager.sendKeyDown(keyCode)
                    connectionManager.sendKeyUp(keyCode)
                }
            }
        }
    }

    // MARK: - Modifier Toggle

    private func modifierToggle(_ label: String, isActive: Binding<Bool>,
                                keyDown: VNCKeyCode, keyUp: VNCKeyCode) -> some View {
        Button(label) {
            isActive.wrappedValue.toggle()
            if isActive.wrappedValue {
                connectionManager.sendKeyDown(keyDown)
            } else {
                connectionManager.sendKeyUp(keyUp)
            }
        }
        .buttonStyle(.bordered)
        .tint(isActive.wrappedValue ? .accentColor : nil)
    }

    // MARK: - Special Key Button

    private func specialKeyButton(_ label: String, keyCode: VNCKeyCode) -> some View {
        Button(label) {
            connectionManager.sendKeyDown(keyCode)
            connectionManager.sendKeyUp(keyCode)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Function Keys

    private var functionKeys: [(label: String, keyCode: VNCKeyCode)] {
        [
            ("F1", .f1), ("F2", .f2), ("F3", .f3), ("F4", .f4),
            ("F5", .f5), ("F6", .f6), ("F7", .f7), ("F8", .f8),
            ("F9", .f9), ("F10", .f10), ("F11", .f11), ("F12", .f12),
        ]
    }

    // MARK: - Release All Modifiers

    private func releaseAllModifiers() {
        if ctrlActive {
            connectionManager.sendKeyUp(.control)
            ctrlActive = false
        }
        if altActive {
            connectionManager.sendKeyUp(.option)
            altActive = false
        }
        if shiftActive {
            connectionManager.sendKeyUp(.shift)
            shiftActive = false
        }
        if cmdActive {
            connectionManager.sendKeyUp(.command)
            cmdActive = false
        }
    }
}
