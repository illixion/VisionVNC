import Foundation

/// Raw byte sequences for the terminal quick-key row and hardware-key mapping.
/// These are the standard xterm/VT100 encodings a PTY expects; sent verbatim
/// over the SSH channel as stdin. Sufficient to drive Claude's TUI (its
/// permission prompts are arrow + enter driven).
nonisolated enum TerminalKeyEncoder {
    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A]   // ESC [ Z
    static let up: [UInt8] = [0x1B, 0x5B, 0x41]         // ESC [ A
    static let down: [UInt8] = [0x1B, 0x5B, 0x42]       // ESC [ B
    static let right: [UInt8] = [0x1B, 0x5B, 0x43]      // ESC [ C
    static let left: [UInt8] = [0x1B, 0x5B, 0x44]       // ESC [ D
    static let ctrlA: [UInt8] = [0x01]                  // SOH (line start)
    static let ctrlC: [UInt8] = [0x03]                  // ETX (interrupt)
    static let ctrlD: [UInt8] = [0x04]                  // EOT
    static let ctrlE: [UInt8] = [0x05]                  // ENQ (line end)
    static let ctrlR: [UInt8] = [0x12]                  // DC2 (reverse search)
    static let ctrlL: [UInt8] = [0x0C]                  // FF (clear)
    static let ctrlZ: [UInt8] = [0x1A]                  // SUB (suspend)
    static let enter: [UInt8] = [0x0D]                  // CR
    static let backspace: [UInt8] = [0x7F]              // DEL
    static let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]   // ESC [ 5 ~
    static let pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E] // ESC [ 6 ~
    static let home: [UInt8] = [0x1B, 0x5B, 0x48]      // ESC [ H
    static let end: [UInt8] = [0x1B, 0x5B, 0x46]       // ESC [ F

    /// Control byte for a single-character string (the ⌃ latch): `a`/`A` →
    /// 0x01 … plus the standard `@ [ \ ] ^ _` controls. nil when the input
    /// isn't a single ASCII char with a control mapping.
    static func controlByte(for text: String) -> UInt8? {
        guard text.count == 1, let scalar = text.uppercased().unicodeScalars.first,
              scalar.isASCII else { return nil }
        let v = UInt8(scalar.value)
        guard (0x40...0x5F).contains(v) else { return nil }  // @ A-Z [ \ ] ^ _
        return v & 0x1F
    }
}

/// A key in the terminal quick-key row. `bytes` go to the PTY verbatim (plain
/// ASCII characters are just their byte). `catalog` is the single source of
/// truth; the user's enabled subset is stored in UserDefaults as comma-joined
/// ids (see `ConnectionDefaults.Keys.terminalQuickKeys`).
nonisolated struct TerminalQuickKey: Identifiable, Equatable {
    enum Group: CaseIterable {
        case navigation, control, paging, characters, editing
    }

    let id: String
    let label: String
    /// Human-readable name for the Settings quick-key editor.
    let name: String
    let bytes: [UInt8]
    let group: Group

    static let catalog: [TerminalQuickKey] = [
        .init(id: "esc", label: "esc", name: "Escape", bytes: TerminalKeyEncoder.escape, group: .navigation),
        .init(id: "tab", label: "tab", name: "Tab", bytes: TerminalKeyEncoder.tab, group: .navigation),
        .init(id: "shift-tab", label: "⇤", name: "Shift-Tab", bytes: TerminalKeyEncoder.shiftTab, group: .navigation),
        .init(id: "up", label: "↑", name: "Up", bytes: TerminalKeyEncoder.up, group: .navigation),
        .init(id: "down", label: "↓", name: "Down", bytes: TerminalKeyEncoder.down, group: .navigation),
        .init(id: "left", label: "←", name: "Left", bytes: TerminalKeyEncoder.left, group: .navigation),
        .init(id: "right", label: "→", name: "Right", bytes: TerminalKeyEncoder.right, group: .navigation),
        .init(id: "ctrl-c", label: "⌃C", name: "Interrupt", bytes: TerminalKeyEncoder.ctrlC, group: .control),
        .init(id: "ctrl-d", label: "⌃D", name: "End of input", bytes: TerminalKeyEncoder.ctrlD, group: .control),
        .init(id: "ctrl-z", label: "⌃Z", name: "Suspend", bytes: TerminalKeyEncoder.ctrlZ, group: .control),
        .init(id: "ctrl-r", label: "⌃R", name: "History search", bytes: TerminalKeyEncoder.ctrlR, group: .control),
        .init(id: "ctrl-l", label: "⌃L", name: "Clear screen", bytes: TerminalKeyEncoder.ctrlL, group: .control),
        .init(id: "ctrl-a", label: "⌃A", name: "Line start", bytes: TerminalKeyEncoder.ctrlA, group: .control),
        .init(id: "ctrl-e", label: "⌃E", name: "Line end", bytes: TerminalKeyEncoder.ctrlE, group: .control),
        .init(id: "page-up", label: "⇞", name: "Page Up", bytes: TerminalKeyEncoder.pageUp, group: .paging),
        .init(id: "page-down", label: "⇟", name: "Page Down", bytes: TerminalKeyEncoder.pageDown, group: .paging),
        .init(id: "home", label: "↖", name: "Home", bytes: TerminalKeyEncoder.home, group: .paging),
        .init(id: "end", label: "↘", name: "End", bytes: TerminalKeyEncoder.end, group: .paging),
        .init(id: "slash", label: "/", name: "Slash", bytes: [0x2F], group: .characters),
        .init(id: "pipe", label: "|", name: "Pipe", bytes: [0x7C], group: .characters),
        .init(id: "tilde", label: "~", name: "Tilde", bytes: [0x7E], group: .characters),
        .init(id: "dash", label: "-", name: "Dash", bytes: [0x2D], group: .characters),
        .init(id: "enter", label: "⏎", name: "Enter", bytes: TerminalKeyEncoder.enter, group: .editing),
        .init(id: "backspace", label: "⌫", name: "Backspace", bytes: TerminalKeyEncoder.backspace, group: .editing),
    ]

    /// Today's row plus the most-wanted additions; used when the user has
    /// never customized the set (the @AppStorage initial value).
    static let defaultSelectionIDs: [String] = [
        "esc", "tab", "shift-tab", "up", "down", "left", "right",
        "ctrl-c", "ctrl-d", "ctrl-z", "ctrl-r", "page-up", "page-down", "enter",
    ]

    static let defaultSelectionStored: String = defaultSelectionIDs.joined(separator: ",")

    /// Decode the stored comma-joined id list. Unknown ids (removed keys) are
    /// dropped; an empty string means the user disabled everything.
    static func enabledIDs(from stored: String) -> Set<String> {
        let known = Set(catalog.map(\.id))
        return Set(stored.split(separator: ",").map(String.init)).intersection(known)
    }

    /// Encode an enabled set in stable catalog order.
    static func encodeSelection(_ enabled: Set<String>) -> String {
        catalog.map(\.id).filter(enabled.contains).joined(separator: ",")
    }
}
