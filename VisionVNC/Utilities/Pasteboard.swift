#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform clipboard write, hiding the `UIPasteboard` / `NSPasteboard`
/// split. Text-only — that's all the app needs (copy a log dump, an SSH public
/// key line, a device code).
enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }
}
