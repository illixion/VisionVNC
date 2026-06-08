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
    static let ctrlC: [UInt8] = [0x03]                  // ETX (interrupt)
    static let ctrlD: [UInt8] = [0x04]                  // EOT
    static let ctrlR: [UInt8] = [0x12]                  // DC2 (reverse search)
    static let ctrlL: [UInt8] = [0x0C]                  // FF (clear)
    static let enter: [UInt8] = [0x0D]                  // CR
    static let backspace: [UInt8] = [0x7F]              // DEL
}
