# VisionVNC — Claude Code Context

## Overview

VisionVNC is a VNC (Virtual Network Computing) viewer app for **visionOS** built in Swift. It uses **RoyalVNCKit** (MIT license, pure Swift) as a local SPM dependency for the VNC/RFB protocol implementation.

## Build Configuration

- **Platform:** visionOS 26.2+
- **Swift version:** 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types are implicitly @MainActor)
- **SWIFT_APPROACHABLE_CONCURRENCY:** YES
- **RoyalVNCKit:** Local SPM package from `repos/royalvnc/` (modified to `.static` library type to avoid dyld embedding issues)
- `repos/` is gitignored — the RoyalVNCKit source lives there but is not committed

## Architecture

### Multi-Window Design

Three `WindowGroup` scenes in `VisionVNCApp`:
1. **Main window** — `ConnectionListView` with SwiftData-backed server list
2. **Remote Desktop** (`id: "remote-desktop"`) — `RemoteDesktopView`, 1280x800 default
3. **Keyboard** (`id: "keyboard"`) — `KeyboardInputView`, 500x400 content-sized

All windows receive the shared `VNCConnectionManager` via `.environment()`.

### Key Types

| Type | Role |
|------|------|
| `VNCConnectionManager` | `@Observable` + `NSObject` + `VNCConnectionDelegate`. Central bridge between RoyalVNCKit and SwiftUI. Manages connection lifecycle, CADisplayLink-throttled rendering, credential flow, and input forwarding. |
| `SavedConnection` | `@Model` (SwiftData). Persists hostname, port, label, quality, auto-login credentials. |
| `ConnectionQuality` | Enum mapping Low (16-bit) / High (24-bit) to `VNCConnection.Settings.ColorDepth`. |
| `GestureTranslator` | Aspect-ratio-aware coordinate conversion from view space to VNC framebuffer coordinates. |

### Threading Pattern

Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, all VNCConnectionDelegate methods must be `nonisolated` with `Task { @MainActor in }` dispatching. RoyalVNCKit is imported with `@preconcurrency import RoyalVNCKit` to suppress Sendable warnings.

### Framebuffer Rendering

`CADisplayLink` throttles framebuffer updates at 30-90 FPS (preferred 60). The delegate sets `pendingImageUpdate = true` on each framebuffer update, and the display link callback reads `framebuffer.cgImage` only when the flag is set.

### Credential Flow

1. `connect()` stores username/password temporarily
2. When the delegate's `credentialFor` callback fires, auto-submits stored credentials if available (supports both VNC password-only and ARD username+password auth)
3. Falls back to presenting `CredentialPromptView` as a sheet if no stored credentials

### Keyboard Input

Two complementary approaches:
- **HardwareKeyboardView** — `UIViewRepresentable` wrapping a `UIView` (`KeyCaptureView`) that overrides `pressesBegan`/`pressesEnded` to intercept hardware/Bluetooth keyboard events. Maps `UIKeyboardHIDUsage` → X11 KeySymbol-based `VNCKeyCode`. Placed as invisible overlay in RemoteDesktopView.
- **KeyboardInputView** — Separate window with soft keyboard controls: text field for typing, modifier toggles (Ctrl/Alt/Shift/Cmd), special keys, arrow keys, F1-F12.

### Window Lifecycle

- Closing the remote desktop window triggers `onDisappear` which disconnects and closes the keyboard window
- Pressing Disconnect immediately closes both windows
- Server-initiated disconnect auto-closes windows after 1 second delay
- Uses `dismissWindow(id:)` (not `dismiss()`) for proper `WindowGroup` window management

## File Structure

```
VisionVNC/
├── VisionVNCApp.swift              — App entry point, three WindowGroup scenes
├── Models/
│   └── SavedConnection.swift       — SwiftData model + ConnectionQuality enum
├── ViewModels/
│   └── VNCConnectionManager.swift  — VNC connection bridge, @Observable
├── Views/
│   ├── ConnectionListView.swift    — Server list (tap to connect, edit button)
│   ├── ConnectionFormView.swift    — Add/edit server form
│   ├── RemoteDesktopView.swift     — Framebuffer display + gestures + toolbar
│   ├── KeyboardInputView.swift     — Soft keyboard window
│   ├── HardwareKeyboardView.swift  — UIViewRepresentable for HW keyboard capture
│   └── CredentialPromptView.swift  — Auth prompt sheet
├── Utilities/
│   └── GestureTranslator.swift     — View-to-framebuffer coordinate mapping
├── Assets.xcassets/                — App icon (solidimagestack, 1024x1024 @2x)
└── Info.plist                      — NSLocalNetworkUsageDescription, multi-scene
```

## RoyalVNCKit API Quick Reference

- **Connection:** `VNCConnection(settings:)`, `.connect()`, `.disconnect()`
- **Settings:** `VNCConnection.Settings(hostname:port:isShared:colorDepth:frameEncodings:...)`
- **Color depths:** `.depth8Bit` (broken — palettized, most servers reject), `.depth16Bit`, `.depth24Bit`
- **Frame encodings:** `[VNCFrameEncodingType].default` → [tight, zlib, zrle, hextile, coRRE, rre]
- **Auth types:** `VNCAuthenticationType` — `.vnc` (password only), `.appleRemoteDesktop` (username+password), `.ultraVNCMSLogonII`
- **Credentials:** `VNCPasswordCredential(password:)`, `VNCUsernamePasswordCredential(username:password:)`
- **Framebuffer:** `VNCFramebuffer` — `.cgImage`, `.cgSize`
- **Mouse:** `.mouseMove(x:y:)`, `.mouseButtonDown/Up(_:x:y:)`, `.mouseWheel(_:x:y:steps:)`
- **Keyboard:** `.keyDown(_:)`, `.keyUp(_:)` with `VNCKeyCode` (X11 KeySymbols)
- **Key codes:** `VNCKeyCode.withCharacter(_:)` for printable chars, static constants for special keys (`.shift`, `.control`, `.option`, `.command`, `.return`, `.escape`, `.f1`–`.f19`, etc.)
- **Compression/JPEG quality:** Hardcoded to level 6 in the library (not configurable without modifying VNCConnection.swift)

## Known Constraints & Gotchas

- **8-bit color depth is broken** with most modern VNC servers (including macOS Screen Sharing). It creates a palettized color map mode (`trueColor: false`) that Tight and ZRLE encodings reject. Low quality uses 16-bit instead.
- **RoyalVNCKit is statically linked** — the library's `Package.swift` was modified from `.dynamic` to `.static` to fix a dyld crash on device. This change lives in `repos/royalvnc/Package.swift` (gitignored).
- **SwiftData migrations** require default values on all new non-optional properties and `@Attribute(originalName:)` for renamed columns, or the store fails to load (CoreData error 134110).
- **`navigationTitle` requires `NavigationStack`** on visionOS — without it, the title bar doesn't render.
- **`dismissWindow(id:)`** is the correct API for closing `WindowGroup` windows on visionOS, not `dismiss()`.
- **`UIKey.characters`** is `String` (non-optional) in this SDK version, not `String?`. Use `.isEmpty` checks instead of optional binding.
