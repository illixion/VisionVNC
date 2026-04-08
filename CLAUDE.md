# VisionVNC — Claude Code Context

## Overview

VisionVNC is a remote desktop and game streaming app for **visionOS** built in Swift. It supports two protocols:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM dependency)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C protocol library) with hardware-accelerated H.264/HEVC decoding and Opus audio

Moonlight is an **optional build-time feature** controlled by the `MOONLIGHT_ENABLED` Swift compilation condition. When disabled, the app is a pure VNC viewer with zero Moonlight code compiled in.

## Build Configuration

- **Platform:** visionOS 26.2+
- **Swift version:** 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types are implicitly @MainActor)
- **SWIFT_APPROACHABLE_CONCURRENCY:** YES
- **RoyalVNCKit:** Local SPM package from `repos/royalvnc/` (modified to `.static` library type to avoid dyld embedding issues)
- **moonlight-common-c:** Local SPM package from `repos/moonlight-common-c/` with CI patches applied (CommonCrypto backend, FEC fixes). Wrapped via `ci/deps/moonlight-common-c/Package.swift`. Includes bundled `enet` networking library.
- **Opus:** Local SPM package from `repos/opus/` for audio decoding. Wrapped via `ci/deps/opus/Package.swift` with custom `module.modulemap` exposing multistream API.
- **MOONLIGHT_ENABLED:** Swift active compilation condition that gates all Moonlight code. Set in Xcode build settings.
- `repos/` is gitignored — all dependency sources live there but are not committed

### CI Dependency Setup

The GitHub Actions workflow (`ci/`) clones dependencies and applies patches:
- `moonlight-common-c-commoncrypto.patch` — Replaces OpenSSL with CommonCrypto/Security.framework for AES-GCM, SHA, HMAC (avoids large binary bloat on Apple platforms)
- `moonlight-common-c-fec-fix.patch` — Fixes audio FEC recovery crash
- `moonlight-common-c-audio-fec-fix.patch` — Compatibility with newer Sunshine pre-release server versions
- `opus-spm-umbrella.patch` — Exposes `opus_multistream.h` via SPM umbrella header

## Architecture

### Multi-Window Design

Five `WindowGroup` scenes in `VisionVNCApp` (three VNC + two Moonlight, conditionally compiled):

1. **Main window** — `ConnectionListView` with SwiftData-backed server list (both VNC and Moonlight)
2. **Remote Desktop** (`id: "remote-desktop"`) — `RemoteDesktopView` for VNC, 1280x800 default
3. **Keyboard** (`id: "keyboard"`) — `KeyboardInputView` for VNC, 500x400
4. **Moonlight Stream** (`id: "moonlight-stream"`) — `MoonlightStreamView`, 1920x1080 default (`#if MOONLIGHT_ENABLED`)
5. **Moonlight Keyboard** (`id: "moonlight-keyboard"`) — `MoonlightKeyboardView`, 500x450 (`#if MOONLIGHT_ENABLED`)

`VNCConnectionManager` and `MoonlightConnectionManager` are injected via `.environment()`. Connection type routing happens in `ConnectionListView` — VNC connections open `RemoteDesktopView`, Moonlight connections present `MoonlightPairingView` as a sheet.

### Key Types — VNC

| Type | Role |
|------|------|
| `VNCConnectionManager` | `@Observable` + `NSObject` + `VNCConnectionDelegate`. Bridge between RoyalVNCKit and SwiftUI. Manages connection lifecycle, CADisplayLink-throttled rendering, credential flow, and input forwarding. |
| `GestureTranslator` | Aspect-ratio-aware coordinate conversion from view space to VNC framebuffer coordinates. |

### Key Types — Moonlight

| Type | Role |
|------|------|
| `MoonlightConnectionManager` | `@Observable`. Central orchestrator — state machine (idle → connecting → pairing → ready → streaming), owns all sub-components, manages CADisplayLink for frame delivery. |
| `NvHTTPClient` | GameStream HTTP/HTTPS client using `NWConnection` (Network.framework). Talks to Sunshine's XML API for server info, app list, launch/resume/quit. Bypasses ATS via custom TLS with client cert mutual auth. |
| `NvPairingManager` | Challenge-response pairing handshake. Derives AES key from PIN+salt, exchanges encrypted challenges, verifies RSA signatures. Supports SHA-256 (server gen >= 7) and SHA-1 (legacy). |
| `CryptoManager` | RSA 2048 key pair generation (Keychain-backed), self-signed X.509 cert builder (ASN.1 DER), PKCS#12 packaging for TLS client identity, AES-128-ECB for pairing. All via CommonCrypto/Security.framework — no OpenSSL. |
| `MoonlightVideoRenderer` | Hardware H.264/HEVC decoding via `VTDecompressionSession`. Processes Annex B NAL units from moonlight-common-c, extracts SPS/PPS/VPS parameter sets, creates `CMVideoFormatDescription`, outputs `CGImage` frames. |
| `MoonlightAudioRenderer` | Opus multistream decoding → `AVAudioEngine` + `AVAudioPlayerNode`. Supports stereo, 5.1, and 7.1 channel configs. Can be muted (decoder still runs for protocol, but AVAudioEngine skipped). |
| `MoonlightStreamBridge` | C callback marshalling layer. Global `nonisolated(unsafe)` references to active renderers/delegate, with C-compatible callback functions that forward to Swift. |
| `MoonlightGamepadManager` | `GameController` framework bridge for up to 4 Bluetooth gamepads (DualSense, Xbox, etc.). Maps analog sticks, triggers, DPAD, and buttons with optional A/B X/Y swap. |
| `MoonlightKeyCodes` | Mapping tables from `UIKeyboardHIDUsage` → Windows Virtual Key codes (VK_*), used for keyboard input to the stream. |
| `MoonlightModels` | Data types: `ServerInfo`, `MoonlightApp`, `MoonlightStreamConfig`, `StreamStats`. |

### Shared Types

| Type | Role |
|------|------|
| `SavedConnection` | `@Model` (SwiftData). Persists hostname, port, label, connection type, quality settings. Extended with ~15 Moonlight-specific optional properties (bitrate, FPS, resolution, codec, audio config, touch mode, etc.). Server cert and UUID stored in UserDefaults (binary data not suitable for SwiftData). |
| `ConnectionType` | Enum: `.vnc` / `.moonlight` (conditionally compiled). Discriminates routing and form fields. |

### Moonlight Connection State Machine

```
idle → connecting → fetchingServerInfo → pairing(pin:) → paired → fetchingApps → ready → launching → streaming
                                                                                                         ↓
Any state can transition to: error(String)                                                         stopStreaming → idle
```

### Threading Patterns

**VNC:** Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, all VNCConnectionDelegate methods must be `nonisolated` with `Task { @MainActor in }` dispatching. RoyalVNCKit is imported with `@preconcurrency import RoyalVNCKit`.

**Moonlight:** moonlight-common-c fires C callbacks on background threads. The bridge uses global `nonisolated(unsafe)` pointers to renderers (only one stream active at a time). Hot paths (video decode, audio decode) stay on the callback thread for performance. State updates marshal to MainActor via `Task { @MainActor in }`. Renderers are `@unchecked Sendable` — they contain unsafe C pointers (VTDecompressionSession, Opus decoder) accessed from the callback thread.

### Video Pipeline (Moonlight)

```
moonlight-common-c (C, background thread)
  → drSubmitDecodeUnit(DECODE_UNIT*)
    → MoonlightVideoRenderer.submitDecodeUnit()
      → Extract Annex B NAL units from buffer linked list
      → Detect SPS/PPS/VPS parameter sets, cache and rebuild CMVideoFormatDescription on change
      → Convert to AVCC format (4-byte length prefix)
      → VTDecompressionSessionDecodeFrame()
        → Output callback: VTCreateCGImageFromCVPixelBuffer() → latestFrame (atomic swap)
          → CADisplayLink (main thread) reads latestFrame → MoonlightConnectionManager.streamFrameImage
            → MoonlightStreamView renders CGImage
```

### Audio Pipeline (Moonlight)

```
moonlight-common-c (C, background thread)
  → arDecodeAndPlaySample(sampleData, sampleLength)
    → MoonlightAudioRenderer.decodeAndPlaySample()
      → opus_multistream_decode() → Int16 PCM
        → AVAudioPCMBuffer → AVAudioPlayerNode.scheduleBuffer()
```

### Framebuffer Rendering (VNC)

`CADisplayLink` throttles framebuffer updates at 30-90 FPS (preferred 60). The delegate sets `pendingImageUpdate = true` on each framebuffer update, and the display link callback reads `framebuffer.cgImage` only when the flag is set.

### Credential Flow (VNC)

1. `connect()` stores username/password temporarily
2. When the delegate's `credentialFor` callback fires, auto-submits stored credentials if available (supports both VNC password-only and ARD username+password auth)
3. Falls back to presenting `CredentialPromptView` as a sheet if no stored credentials

### Keyboard Input

**VNC:**
- `HardwareKeyboardView` — `UIViewRepresentable` wrapping `KeyCaptureView` that overrides `pressesBegan`/`pressesEnded` to intercept hardware/Bluetooth keyboard events. Maps `UIKeyboardHIDUsage` → X11 KeySymbol-based `VNCKeyCode`.
- `KeyboardInputView` — Separate window with soft keyboard controls.

**Moonlight:**
- `MoonlightHardwareKeyboardView` — Same pattern but maps `UIKeyboardHIDUsage` → Windows VK codes via `MoonlightKeyCodes`, sends via `LiSendKeyboardEvent()`.
- `MoonlightKeyboardView` — Separate window with soft keyboard, modifier toggles, special keys, function keys. Text input sends character-by-character key events.

### Mouse/Gesture Input (Moonlight)

Two modes controlled by `SavedConnection.moonlightTouchMode`:
- **Relative** (default, for games): Drag gestures send incremental mouse deltas via `LiSendMouseMoveEvent()`
- **Absolute** (for desktop): Tap/drag positions mapped to stream resolution via `LiSendMousePositionEvent()`

Gestures: single tap = left click, double tap = right click, two-finger press-and-hold = right click, scroll wheel via `LiSendScrollEvent()`.

### Gamepad Input (Moonlight)

`MoonlightGamepadManager` uses `GameController` framework. Supports up to 4 Bluetooth controllers. Maps GCExtendedGamepad inputs to `LiSendMultiControllerEvent()` with button flags, trigger pressure, and analog stick values. Optional A/B X/Y swap for Nintendo layout.

### Window Lifecycle

- Closing the remote desktop / stream window triggers `onDisappear` which disconnects and closes the keyboard window
- Pressing Disconnect immediately closes both windows
- Server-initiated disconnect auto-closes windows after 1 second delay
- Uses `dismissWindow(id:)` (not `dismiss()`) for proper `WindowGroup` window management
- Moonlight disconnect offers choice: end session on server (quit app) or keep running (local disconnect only)

### Moonlight Networking Details

**NvHTTPClient** uses `NWConnection` (Network.framework) instead of `URLSession` because:
- Sunshine uses self-signed TLS certs — `NWConnection` allows custom cert verification without ATS exceptions
- Mutual TLS authentication requires presenting client identity (PKCS#12) during handshake
- HTTP/1.1 requests are manually constructed and responses parsed (strip headers, extract XML body)

**XML Parsing:** Three `NSXMLParser` subclasses handle different response formats — flat key-value (server info), display mode lists, and app lists with HDR flags.

**Audio config encoding** for the `/launch` request: `((channelMask) << 16) | (channelCount << 8) | 0xCA` — e.g., stereo = `0x302CA`, 5.1 = `0x3F06CA`.

## File Structure

```
VisionVNC/
├── VisionVNCApp.swift                  — App entry, 5 WindowGroup scenes (2 Moonlight conditional)
├── Models/
│   └── SavedConnection.swift           — SwiftData model, ConnectionType, Moonlight settings enums
├── ViewModels/
│   ├── VNCConnectionManager.swift      — VNC connection bridge, @Observable
│   └── MoonlightConnectionManager.swift — Moonlight orchestrator, state machine, @Observable
├── Views/
│   ├── ConnectionListView.swift        — Server list, routes by connection type
│   ├── ConnectionFormView.swift        — Add/edit form (VNC + Moonlight settings sections)
│   ├── RemoteDesktopView.swift         — VNC framebuffer display + gestures + toolbar
│   ├── KeyboardInputView.swift         — VNC soft keyboard window
│   ├── HardwareKeyboardView.swift      — VNC hardware keyboard capture (UIViewRepresentable)
│   ├── CredentialPromptView.swift      — VNC auth prompt sheet
│   ├── MoonlightPairingView.swift      — Pairing flow, PIN display, app picker, launch
│   ├── MoonlightStreamView.swift       — Stream display, gesture input, controls ornament
│   ├── MoonlightKeyboardView.swift     — Moonlight soft keyboard window
│   ├── MoonlightHardwareKeyboardView.swift — Moonlight hardware keyboard capture
│   └── StreamStatsOverlay.swift        — Live stats HUD (codec, FPS, RTT, decode time, drops)
├── Moonlight/
│   ├── MoonlightStreamBridge.swift     — C callback → Swift marshalling, global renderer refs
│   ├── MoonlightVideoRenderer.swift    — VTDecompressionSession H.264/HEVC decoder
│   ├── MoonlightAudioRenderer.swift    — Opus multistream → AVAudioEngine
│   ├── MoonlightGamepadManager.swift   — GameController framework → LiSendMultiControllerEvent
│   ├── MoonlightKeyCodes.swift         — UIKeyboardHIDUsage → Windows VK code mapping
│   ├── MoonlightModels.swift           — ServerInfo, MoonlightApp, StreamConfig, StreamStats
│   ├── NvHTTPClient.swift              — GameStream HTTP API (NWConnection, XML parsing)
│   ├── NvPairingManager.swift          — Challenge-response pairing handshake
│   └── CryptoManager.swift             — X.509, PKCS#12, AES-128-ECB, RSA (CommonCrypto)
├── Utilities/
│   └── GestureTranslator.swift         — View-to-framebuffer coordinate mapping (VNC)
├── Assets.xcassets/                    — App icon (solidimagestack, 1024x1024 @2x)
└── Info.plist                          — NSLocalNetworkUsageDescription, multi-scene

ci/
├── deps/
│   ├── moonlight-common-c/Package.swift — SPM wrapper (MoonlightCommonC + enet targets)
│   └── opus/
│       ├── Package.swift               — SPM wrapper for Opus C library
│       ├── include/module.modulemap    — Exposes multistream API
│       └── spm-config/config.h         — Build configuration
├── patches/
│   ├── moonlight-common-c-commoncrypto.patch — Replace OpenSSL with CommonCrypto
│   ├── moonlight-common-c-fec-fix.patch      — Audio FEC crash fix
│   ├── moonlight-common-c-audio-fec-fix.patch — Newer Sunshine compat
│   └── opus-spm-umbrella.patch               — Multistream header exposure
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

## moonlight-common-c API Quick Reference

- **Session:** `LiStartConnection()` / `LiStopConnection()` — takes `SERVER_INFORMATION`, `STREAM_CONFIGURATION`, and callback structs
- **Callbacks:** `CONNECTION_LISTENER_CALLBACKS` (stage/connection events), `DECODER_RENDERER_CALLBACKS` (video), `AUDIO_RENDERER_CALLBACKS` (audio)
- **Video callback:** `drSubmitDecodeUnit(DECODE_UNIT*)` — linked list of `LENTRY` buffers containing Annex B H.264/HEVC NAL units
- **Audio callback:** `arDecodeAndPlaySample(sampleData, sampleLength)` — Opus-encoded audio packets
- **Mouse:** `LiSendMouseMoveEvent(deltaX, deltaY)`, `LiSendMousePositionEvent(x, y, refWidth, refHeight)`, `LiSendMouseButtonEvent(action, button)`, `LiSendScrollEvent(direction)`
- **Keyboard:** `LiSendKeyboardEvent(keyAction, keyCode, modifiers)` — uses Windows VK codes, actions `KEY_ACTION_DOWN` (0x0801) / `KEY_ACTION_UP` (0x0802)
- **Gamepad:** `LiSendMultiControllerEvent(controllerNumber, activeGamepadMask, buttonFlags, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY)`
- **Stats:** `LiGetEstimatedRttInfo()` for network RTT; frame counts and decode timing tracked in `MoonlightVideoRenderer`
- **Stage names:** STAGE_RTSP_HANDSHAKE, STAGE_CONTROL_STREAM, STAGE_VIDEO_STREAM, STAGE_AUDIO_STREAM, STAGE_INPUT_STREAM — surfaced via `LiGetStageName()`

## Known Constraints & Gotchas

### VNC
- **8-bit color depth is broken** with most modern VNC servers (including macOS Screen Sharing). It creates a palettized color map mode (`trueColor: false`) that Tight and ZRLE encodings reject. Low quality uses 16-bit instead.
- **RoyalVNCKit is statically linked** — the library's `Package.swift` was modified from `.dynamic` to `.static` to fix a dyld crash on device. This change lives in `repos/royalvnc/Package.swift` (gitignored).

### Moonlight
- **C callbacks fire on background threads** — renderers use `nonisolated(unsafe)` globals and `@unchecked Sendable` conformance. Only one stream is active at a time; the bridge stores a global reference to the active manager/renderers.
- **CryptoManager builds X.509 certs from scratch** using ASN.1 DER helpers (no OpenSSL). The cert, private key (Keychain), and PKCS#12 are cached in UserDefaults. If the Keychain is reset, the client identity is regenerated and all servers must be re-paired.
- **NvHTTPClient uses NWConnection, not URLSession** — required for self-signed cert acceptance and mutual TLS. HTTP/1.1 is manually constructed. Responses are XML parsed with Foundation's `XMLParser`.
- **Server cert and UUID are stored in UserDefaults**, keyed per server — SwiftData doesn't handle raw `Data` blobs well for binary cert data.
- **Opus multistream decoder** requires channel count, stream count, coupled stream count, and channel mapping from the `OPUS_MULTISTREAM_CONFIGURATION` provided by moonlight-common-c. The decoder is always created even in muted mode (C API requirement), but AVAudioEngine is skipped.
- **Video renderer outputs CGImage** (not direct Metal/AVSampleBufferDisplayLayer) for simpler integration with SwiftUI. This adds ~1ms overhead per frame but avoids UIViewRepresentable complexity for the display layer.
- **AV1 is not supported** — would require FFmpeg for bitstream parsing (sequence header extraction). H.264 and HEVC work natively via VideoToolbox.
- **HDR is not supported** — would require HEVC Main 10 profile + EDR rendering. The codec preference enum includes `.av1` but it's effectively a no-op.
- **Audio FEC patches are required** — without the CI patches, moonlight-common-c crashes on FEC recovery with newer Sunshine versions. Always apply patches from `ci/patches/` when setting up the dependency.
- **Pairing supports two hash variants** — SHA-256 for server generation >= 7 (modern Sunshine), SHA-1 for older servers. The `NvPairingManager` auto-detects based on `/serverinfo` response.

### General
- **SwiftData migrations** require default values on all new non-optional properties and `@Attribute(originalName:)` for renamed columns, or the store fails to load (CoreData error 134110).
- **`navigationTitle` requires `NavigationStack`** on visionOS — without it, the title bar doesn't render.
- **`dismissWindow(id:)`** is the correct API for closing `WindowGroup` windows on visionOS, not `dismiss()`.
- **`UIKey.characters`** is `String` (non-optional) in this SDK version, not `String?`. Use `.isEmpty` checks instead of optional binding.
