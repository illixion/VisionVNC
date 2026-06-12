# VisionVNC — Claude Code Context

## Overview

VisionVNC is a remote desktop and game streaming app for **visionOS** built in Swift. It supports two protocols:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM dependency)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C protocol library) with hardware-accelerated H.264/HEVC/AV1 decoding, HDR10 support, and Opus audio
3. **Audio** — Uncompressed system-audio streaming from a companion macOS menu bar app (`VisionVNCCompanion` target). Works around macOS forcing Spatial Audio on for Mac Virtual Display: audio played by this app honors the per-app Spatial Audio setting. Also carries Music.app now-playing metadata (title/artist/artwork) to the Vision Pro and transport commands (play/pause/next/prev) back to the Mac; the visionOS side is an iTunes-style mini player.
4. **SSH / Remote Claude** — A built-in SSH terminal client ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT + [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) Apache-2.0, pure Swift) for any host, plus a **Projects** tab that drives Claude Code (or another configurable CLI) on a Mac over SSH — tmux-backed for persistence, with a gaze/dictation composer + quick-key row. The device identity is a Secure Enclave P-256 key; only its public key is installed on the host. Because the macOS Keychain is unreachable over SSH, Claude auth uses a `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) stored in the Vision Pro keychain and injected inline per session — no `sshd_config` edit. The companion macOS app also gained **text-only keyboard injection** (CGEvent Unicode + backspace, no modifiers — DuckyScript-safe) so the VNC soft keyboard can route typing through the Mac when a companion is linked.

5. **Broadcast** — streams Vision Pro cameras/view + mic to a mediamtx RTSP server (for OBS / video calls on a computer). Two publishers share one hand-rolled pipeline (`BroadcastCore/`: VideoToolbox H.264 + **native AudioToolbox Opus** (`kAudioFormatOpus` via `AVAudioConverter` — deliberately NOT the vendored libopus, which is stubbed in CI) → RTP/RTSP over `NWConnection`, Basic auth, RTCP SRs): (a) the **Broadcast tab** captures an `AVCaptureDevice` (only Persona/"Front Camera" exists — visionOS exposes no view device) + `AVAudioEngine` mic tap, foreground-only; (b) the **`VisionVNCBroadcast` broadcast upload extension** (ReplayKit `RPBroadcastSampleHandler`, started from the system View Sharing menu or the in-tab `RPSystemBroadcastPickerView`) receives the composited "Mirror My View" feed + mic and keeps streaming while the app is backgrounded, publishing to a separate stream path. Config flows app → extension via app-group UserDefaults + app-group-scoped keychain item (`BroadcastShared`); both targets need the `group.com.illixion.VisionVNC` App Group entitlement (provisioning must include it). Server provisioning is one-button from the macOS companion (`BroadcastServerManager`): generates publish password + self-signed TLS cert, writes the managed mediamtx config (RTSPS-strict ingest :8322, WHEP out on localhost), restarts the brew service, and AirDrops a `visionvnc://…/setBroadcastServer` pairing URL (`Shared/BroadcastSetupURL.swift`) carrying host/creds/cert-fingerprint; the publishers then use RTSPS with DER-SHA256 cert pinning (Moonlight-style trust, fingerprint empty = plain RTSP). The companion can also provision the OBS side ("Add Sources to OBS", `OBSWebSocketClient`): both WHEP Browser Sources created/updated in the current scene via obs-websocket v5, audio routed into the mixer, camera visible on top + view hidden.

There are two **companion apps** for the host side (see `CompanionMac/` and `CompanionWindows/`):

- **macOS Companion** (`VisionVNCCompanion` target, source in `CompanionMac/`) — the audio / now-playing / keyboard-injection / SSH-key companion described above.
- **Windows Hotspot Companion** (`CompanionWindows/`, a **PoC**, separate Node + .NET codebase) — turns a Windows host into a NAT'd Wi-Fi access point the Vision Pro joins directly, so the headset rides behind the PC's NAT (defeating café/hotel AP-isolation) and reaches the local Sunshine/VNC server at the gateway. Uses the Windows Mobile Hotspot API (`NetworkOperatorTetheringManager`) via a `.NET` backend, fronted by an Electron UI over an ACL'd named pipe. The visionOS side complements it with `LocalNetwork.swift` (auto-prefills the `192.168.137.1` gateway host on a Windows-ICS subnet). It does **not** share compiled code with the macOS companion; the audio/inject TLS-PSK channel is not exercised in the PoC.

Moonlight is an **optional build-time feature** controlled by the `MOONLIGHT_ENABLED` Swift compilation condition. When disabled, the app is a pure VNC viewer with zero Moonlight code compiled in.

## Build Configuration

- **Platform:** visionOS 26.2+
- **Swift version:** 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types are implicitly @MainActor)
- **SWIFT_APPROACHABLE_CONCURRENCY:** YES
- **RoyalVNCKit:** Local SPM package from `repos/royalvnc/`, modified beyond upstream: `.static` library type (dyld fix), per-connection `jpegQualityLevel`/`compressionLevel` settings, and `pauseFramebufferUpdates`/`resumeFramebufferUpdates`. The full delta vs the pinned ref is committed as `ci/patches/royalvnc-visionvnc.patch`. **REQUIREMENT: after any edit inside `repos/royalvnc`, re-export the patch** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-visionvnc.patch` — or CI and fresh local setups will fail to compile the app.
- **moonlight-common-c:** Local SPM package from `repos/moonlight-common-c/` with CI patches applied (CommonCrypto backend, FEC fixes). Wrapped via `ci/deps/moonlight-common-c/Package.swift`. Includes bundled `enet` networking library.
- **Opus:** Local SPM package from `repos/opus/` for audio decoding. Wrapped via `ci/deps/opus/Package.swift` with custom `module.modulemap` exposing multistream API.
- **MOONLIGHT_ENABLED:** Swift active compilation condition that gates all Moonlight code. Set in Xcode build settings.
- `repos/` is gitignored — all dependency sources live there but are not committed

### Dependency Setup (CI + local)

**CI builds both IPAs on one runner** (`.github/workflows/build.yml`, triggers on push to main + manual dispatch). Order matters for licensing: it first archives the **MIT IPA** with the moonlight-common-c and opus packages stubbed out as empty SPM packages (same product names, nothing compiled — guarantees no GPL code links in), plus the unsigned macOS Companion zip; then swaps the stubs for the real patched dependencies (`rm -rf` the two stub dirs + `scripts/setup-deps.sh`, which skips the already-present RoyalVNC) and archives the **GPLv3 Moonlight-enabled IPA** with `MOONLIGHT_ENABLED`. The Moonlight build is a required step, not best-effort (a historical enet compile failure on the runner image turned out to be an unsynced patch — see the patch-export REQUIREMENT above). One release gets all three artifacts via `gh release create`.

**Local Moonlight-enabled builds** use `scripts/setup-deps.sh` (idempotent, `--force` to redo), which recreates the full dependency setup in gitignored `repos/`:
- `royalvnc-visionvnc.patch` — Static linking + VisionVNC API additions (see Build Configuration above)
- `moonlight-common-c-commoncrypto.patch` — Replaces OpenSSL with CommonCrypto/Security.framework for AES-GCM, SHA, HMAC (avoids large binary bloat on Apple platforms)
- `moonlight-common-c-fec-fix.patch` — Fixes audio FEC recovery crash
- `moonlight-common-c-audio-fec-fix.patch` — Compatibility with newer Sunshine pre-release server versions
- `opus-spm-umbrella.patch` — Exposes `opus_multistream.h` via SPM umbrella header

Other scripts: `scripts/build-and-sign.sh` (config-driven device build+sign+deploy; reads gitignored `scripts/build-signing.conf`, runs setup-deps as pre-build hook, passes `MOONLIGHT_ENABLED` via `EXTRA_BUILD_SETTINGS`), `scripts/release.sh` (local Moonlight-enabled GitHub release via `gh`), `scripts/install-companion.sh` (build the macOS companion and install it to `/Applications`, quitting + relaunching it — TCC perms and the token live with the installed app, not Xcode's DerivedData build).

### Testing

Unit tests live in `VisionVNCTests/` (app-hosted XCTest target, visionOS). **Run locally — there is no CI test job** (CI only archives):

```
xcodebuild test -scheme VisionVNCTests -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5'
```

The target is wired via a **shared** scheme (`VisionVNC.xcodeproj/xcshareddata/xcschemes/VisionVNCTests.xcscheme`) so the command resolves headlessly; the `VisionVNC`/`VisionVNCCompanion` schemes still autocreate. `VisionVNCTests/` is a `PBXFileSystemSynchronizedRootGroup`, so new `*.swift` files there auto-compile into the test target — no pbxproj edits needed. Tests `@testable import VisionVNC` and run in **Debug** (the app's Debug config sets `ENABLE_TESTABILITY = YES`).

Current coverage is the pure, regression-prone logic: `TextDiff` (keyboard diff), `CompanionInjectProtocol` (framing/drain/backspace), and `SavedConnection` SSH env parsing/validation. Not yet covered (need extra target linkage): `SecureEnclaveSSHKey` OpenSSH encoding (needs `Crypto`) and the macOS-only `InjectionService` surrogate-safe chunking (needs a macOS test target).

## Architecture

### Multi-Window Design

Seven `WindowGroup` scenes in `VisionVNCApp` (two conditionally compiled):

1. **Main window** (`id: "main"`) — `MainView` with a bottom-ornament tab bar: **Connections** (`ConnectionListView`, SwiftData-backed server list), **Settings** (`SettingsView`, new-connection defaults via `@AppStorage`/`ConnectionDefaults`), **Console** (`ConsoleView`, in-app log viewer)
2. **Console** (`id: "console"`) — pop-out `ConsoleView`, 760x480
3. **Audio Stream** (`id: "audio-stream"`) — `AudioStreamView` mini player, 400x540
4. **Remote Desktop** (`id: "remote-desktop"`) — `RemoteDesktopView` for VNC, 1280x800 default
5. **Keyboard** (`id: "keyboard"`) — `KeyboardInputView` for VNC, 500x400
6. **Moonlight Stream** (`id: "moonlight-stream"`) — `MoonlightStreamView`, 1920x1080 default (`#if MOONLIGHT_ENABLED`)
7. **Moonlight Keyboard** (`id: "moonlight-keyboard"`) — `MoonlightKeyboardView`, 500x450 (`#if MOONLIGHT_ENABLED`)

`VNCConnectionManager`, `AudioStreamManager`, and `MoonlightConnectionManager` are injected via `.environment()`. Connection type routing happens in `ConnectionListView` — VNC/audio connections **push** their windows (`pushWindow`), Moonlight presents `MoonlightPairingView` as a sheet which pushes the stream window on launch.

**Window navigation:** connection windows open via `pushWindow` so the main window goes into the back stack and restores automatically on dismiss; managers track `openedViaPush`. Sub-windows also carry a Home ornament (`.homeOrnament()`, bottom-front) that opens `id: "main"` — needed because visionOS reopens the last-used window on app launch. The audio mini player instead has home + reload buttons in its utility row (the ornament overlapped its transport controls).

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
| `MoonlightVideoRenderer` | H.264/HEVC/AV1 video via `AVSampleBufferDisplayLayer`. Processes Annex B NAL units (H.264/HEVC) or OBUs (AV1) from moonlight-common-c, extracts parameter sets, creates `CMVideoFormatDescription` with HDR metadata extensions (MDCV/CLL), and enqueues `CMSampleBuffer`s to the display layer which handles hardware decoding and HDR rendering. |
| `MoonlightAudioRenderer` | Opus multistream decoding → `AVAudioEngine` + `AVAudioPlayerNode`. Supports stereo, 5.1, and 7.1 channel configs. Can be muted (decoder still runs for protocol, but AVAudioEngine skipped). |
| `MoonlightStreamBridge` | C callback marshalling layer. Global `nonisolated(unsafe)` references to active renderers/delegate, with C-compatible callback functions that forward to Swift. |
| `MoonlightGamepadManager` | `GameController` framework bridge for up to 4 Bluetooth gamepads (DualSense, Xbox, etc.). Maps analog sticks, triggers, DPAD, and buttons with optional A/B X/Y swap. |
| `MoonlightKeyCodes` | Mapping tables from `UIKeyboardHIDUsage` → Windows Virtual Key codes (VK_*), used for keyboard input to the stream. |
| `MoonlightModels` | Data types: `ServerInfo`, `MoonlightApp`, `MoonlightStreamConfig`, `StreamStats`. |

### Key Types — Audio Streaming

| Type | Role |
|------|------|
| `AudioStreamProtocol` / `AudioStreamHeader` | Wire format **v6** (in `Shared/`, compiled into both targets). TCP: 16-byte header (magic `VVAS`, version=6, channels, Float64 sample rate), then typed length-prefixed frames `[UInt32 len][UInt8 type][payload]`: `pcm` 0x00 (interleaved **signed int24**, little-endian, 3 bytes/sample — see `PCM24`; v6 replaced the Float32 wire format for a 25% bandwidth cut, decoded back to Float32 for AVAudioEngine at the receiver), `nowPlaying` 0x01 (JSON), `artwork` 0x02 (scaled JPEG, sent before its matching nowPlaying), `command` 0x03 (JSON, client→server), `udpHello` 0x06 / `keepAlive` 0x07 (low-latency UDP path). Little-endian. Default port 4855. Version mismatch hard-fails at header parse (both apps released together). |
| `NowPlayingInfo` / `MediaCommand` (Shared) | Codable payloads: track metadata snapshot (elapsed extrapolated client-side while playing, `artworkID` = Music persistent ID) and transport commands (play/pause/toggle/next/previous). |
| `AudioStreamManager` (visionOS) | `@Observable` MainActor state holder; owns an `AudioStreamReceiver`. Persists last connection (UserDefaults) and auto-reconnects on space restoration / scenePhase activation (`ensureConnected()`, 2.5 s data-activity health probe) with capped-backoff retry on drops; immediate reload on `.reloadRequested` (audio session lost). `userDisconnect()` clears persistence; window close uses a 2 s grace teardown. |
| `AudioStreamReceiver` (visionOS) | `@unchecked Sendable`, off-main NWConnection receive loop → AVAudioEngine/AVAudioPlayerNode. Prebuffers 4 frames before `play()` to absorb jitter. Local mute drops PCM (no backlog). Observes audio-session interruption/engine-config-change/silence-hint and emits `.reloadRequested` (see Gotchas). |
| `SystemAudioTap` (macOS) | Core Audio process tap (`CATapDescription` global stereo mixdown, macOS 14.2+) hosted in a private aggregate device; IOProc converts the tap's Float32 to interleaved int24 (the wire format) before delivery. `muteSystemOutput` uses `.muted` tap behavior — silences local/Sidecar output while capturing (the whole point: only the streamed copy is audible). Mute change requires tap restart. No BlackHole/virtual driver needed. Requires TCC "System Audio Recording" (NSAudioCaptureUsageDescription). |
| `AudioStreamServer` (macOS) | NWListener TCP server, **single client (newest-wins: new connection displaces the old)**, per-client backpressure: PCM frames dropped for a client >200 KB behind (latency cap). Metadata/artwork frames bypass the cap and are replayed to newly connected clients after the header. Inbound loop parses `command` frames → `onCommand`. |
| `AudioStreamerController` (macOS) | `@Observable` orchestrator behind the `MenuBarExtra` UI in `CompanionApp`. Tap starts **unmuted**; restarts muted on the 0→1 client edge and unmuted on 1→0 (mute only while someone is listening). |
| `MusicAppBridge` (macOS) | Music.app metadata + control via public APIs only: `DistributedNotificationCenter` `com.apple.Music.playerInfo` (event-driven) + `NSAppleScript` one-shots for artwork (≤600 px JPEG, on track change), player position, and transport. Every script call is guarded by an `NSRunningApplication` check (`tell application "Music"` would launch it). Needs `NSAppleEventsUsageDescription` / one-time Automation TCC. |

### Shared Types

| Type | Role |
|------|------|
| `SavedConnection` | `@Model` (SwiftData). Persists hostname, port, label, connection type, quality settings. Extended with ~15 Moonlight-specific optional properties (bitrate, FPS, resolution, codec, audio config, touch mode, etc.). Server cert and UUID stored in UserDefaults (binary data not suitable for SwiftData). |
| `ConnectionType` | Enum: `.vnc` / `.moonlight` (conditionally compiled) / `.audio`. Discriminates routing and form fields. |
| `ConnectionDefaults` | UserDefaults-backed new-connection defaults (VNC quality/touch mode, ports, Moonlight video/audio/input), edited in the Settings tab and seeded into `ConnectionFormView` for new connections. |

### Moonlight Connection State Machine

```
idle → connecting → fetchingServerInfo → pairing(pin:) → paired → fetchingApps → ready → launching → streaming
                                                                                                         ↓
Any state can transition to: error(String)                                                         stopStreaming → idle
```

### Threading Patterns

**VNC:** Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, all VNCConnectionDelegate methods must be `nonisolated` with `Task { @MainActor in }` dispatching. RoyalVNCKit is imported with `@preconcurrency import RoyalVNCKit`.

**Moonlight:** moonlight-common-c fires C callbacks on background threads. The bridge uses global `nonisolated(unsafe)` pointers to renderers (only one stream active at a time). Hot paths (video sample buffer creation, audio decode) stay on the callback thread for performance. State updates marshal to MainActor via `Task { @MainActor in }`. Renderers are `@unchecked Sendable` — they contain unsafe pointers (AVSampleBufferDisplayLayer, Opus decoder) accessed from the callback thread.

### Video Pipeline (Moonlight)

```
moonlight-common-c (C, background thread)
  → drSubmitDecodeUnit(DECODE_UNIT*)
    → MoonlightVideoRenderer.submitDecodeUnit()
      → H.264/HEVC: Extract Annex B NAL units, detect SPS/PPS/VPS, convert to AVCC (4-byte length prefix)
      → AV1: Concatenate OBU data, parse sequence header on IDR for format description
      → Create/update CMVideoFormatDescription (with HDR MDCV/CLL extensions if active)
      → Create CMSampleBuffer with PTS from rtpTimestamp (90kHz timescale)
      → AVSampleBufferDisplayLayer.enqueue() — layer handles hardware decode + display + HDR tone mapping
        → VideoDisplayView (UIViewRepresentable) hosts the layer in MoonlightStreamView
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

- Closing the remote desktop / stream window triggers `onDisappear` which disconnects and closes the keyboard window. The audio window instead uses a 2 s grace teardown (visionOS fires transient onDisappear during space restoration).
- Pressing Disconnect immediately closes the windows; server-initiated VNC disconnect auto-closes after 1 second
- Uses `dismissWindow(id:)` (not `dismiss()`) for proper `WindowGroup` window management
- **visionOS refuses to programmatically close the app's last window.** Connection windows are pushed (`pushWindow`) so dismissal restores the manager from the back stack; standalone windows (space-restoration relaunch, `openedViaPush == false`) explicitly `openWindow(id: "main")` before dismissing. Don't reset `openedViaPush` in dismissal handlers — multiple dismissal paths can fire for one disconnect (caused spurious manager windows once).
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
├── VisionVNCApp.swift                  — App entry, 7 WindowGroup scenes (2 Moonlight conditional)
├── Models/
│   └── SavedConnection.swift           — SwiftData model, ConnectionType, Moonlight settings enums
├── ViewModels/
│   ├── VNCConnectionManager.swift      — VNC connection bridge, @Observable
│   ├── AudioStreamManager.swift        — Audio manager + AudioStreamReceiver (reconnect, mute, now-playing)
│   ├── LogStore.swift                  — OSLogStore poller backing the Console tab/window
│   └── MoonlightConnectionManager.swift — Moonlight orchestrator, state machine, @Observable
├── Views/
│   ├── MainView.swift                  — Main window: ornament tab bar (Connections/Settings/Console)
│   ├── ConnectionListView.swift        — Server list, routes by connection type (pushWindow)
│   ├── ConnectionFormView.swift        — Add/edit form, seeded from ConnectionDefaults
│   ├── SettingsView.swift              — New-connection defaults (@AppStorage)
│   ├── ConsoleView.swift               — Log viewer (tab + "console" pop-out window)
│   ├── AudioStreamView.swift           — Audio mini player (album art, transport, mute, utility row)
│   ├── HomeOrnamentModifier.swift      — Home ornament for sub-windows (opens id "main")
│   ├── RemoteDesktopView.swift         — VNC framebuffer display + gestures + toolbar
│   ├── KeyboardInputView.swift         — VNC soft keyboard window
│   ├── HardwareKeyboardView.swift      — VNC hardware keyboard capture (UIViewRepresentable)
│   ├── CredentialPromptView.swift      — VNC auth prompt sheet
│   ├── ThirdPartyNoticesView.swift     — Parses THIRD_PARTY_NOTICES.md by H2 headings
│   ├── MoonlightPairingView.swift      — Pairing flow, PIN display, app picker, launch
│   ├── MoonlightStreamView.swift       — Stream display, gesture input, controls ornament
│   ├── MoonlightKeyboardView.swift     — Moonlight soft keyboard window
│   ├── MoonlightHardwareKeyboardView.swift — Moonlight hardware keyboard capture
│   └── StreamStatsOverlay.swift        — Live stats HUD (codec, FPS, RTT, decode time, drops)
├── Moonlight/
│   ├── MoonlightStreamBridge.swift     — C callback → Swift marshalling, global renderer refs
│   ├── MoonlightVideoRenderer.swift    — AVSampleBufferDisplayLayer H.264/HEVC/AV1 + HDR
│   ├── MoonlightAudioRenderer.swift    — Opus multistream → AVAudioEngine
│   ├── MoonlightGamepadManager.swift   — GameController framework → LiSendMultiControllerEvent
│   ├── MoonlightKeyCodes.swift         — UIKeyboardHIDUsage → Windows VK code mapping
│   ├── MoonlightModels.swift           — ServerInfo, MoonlightApp, StreamConfig, StreamStats
│   ├── NvHTTPClient.swift              — GameStream HTTP API (NWConnection, XML parsing)
│   ├── NvPairingManager.swift          — Challenge-response pairing handshake
│   └── CryptoManager.swift             — X.509, PKCS#12, AES-128-ECB, RSA (CommonCrypto)
├── Utilities/
│   ├── AppLog.swift                    — os.Logger per category + Logger.line() helper
│   ├── ConnectionDefaults.swift        — UserDefaults keys/getters for new-connection defaults
│   └── GestureTranslator.swift         — View-to-framebuffer coordinate mapping (VNC)
├── Assets.xcassets/                    — App icon (solidimagestack, 1024x1024 @2x)
└── Info.plist                          — NSLocalNetworkUsageDescription, multi-scene

Shared/                                 — compiled into BOTH targets (visionOS app + macOS companion)
├── AudioStreamProtocol.swift           — Wire protocol v6 (int24 PCM via PCM24), NowPlayingInfo, MediaCommand
└── BroadcastSetupURL.swift             — visionvnc://…/setBroadcastServer pairing payload (host/creds/cert fingerprint)

BroadcastCore/                          — compiled into BOTH the app and the broadcast extension
├── BroadcastShared.swift               — app-group config/keychain bridge + broadcastLog (AppLog is app-only)
├── RTPPacketizer.swift                 — RTP/RTCP framing, H.264 RFC 6184 + Opus RFC 7587 (unit-tested)
├── SDPBuilder.swift                    — ANNOUNCE SDP from live SPS/PPS (unit-tested)
├── RTSPPublisher.swift                 — RTSP record client over NWConnection, interleaved RTP, Basic auth
├── BroadcastVideoEncoder.swift         — VTCompressionSession H.264 (realtime, no B-frames, 1 s GOP)
└── BroadcastAudioEncoder.swift         — AVAudioConverter → native Opus (PCM-buffer + CMSampleBuffer entry points)

BroadcastExtension/                     — VisionVNCBroadcast target (ReplayKit broadcast upload extension)
└── SampleHandler.swift                 — Mirror My View + mic → BroadcastCore pipeline → mediamtx

CompanionMac/                           — macOS menu bar companion target (VisionVNCCompanion)
├── CompanionApp.swift                  — MenuBarExtra (slim quick-controls popover) + Settings scene + AudioStreamerController
├── CompanionWindowView.swift           — multi-pane companion window (sidebar + grouped forms: audio/token/broadcast/SSH/keyboard); Settings scene keeps the app menu-bar-only (no auto-open at launch), activation policy flips .regular↔.accessory with the window
├── AudioStreamServer.swift             — Single-client TCP server, metadata replay, command rx
├── SystemAudioTap.swift                — Core Audio process tap
├── MusicAppBridge.swift                — Music.app metadata/control (notifications + AppleScript)
├── BroadcastServerManager.swift        — one-button mediamtx setup (cert/password gen, managed config, brew restart, pairing URL) + one-click OBS scene provisioning
├── OBSWebSocketClient.swift            — minimal obs-websocket v5 client (Hello/Identify challenge auth, Browser Source create/update + visibility/stacking enforcement)
└── Info.plist                          — NSAudioCaptureUsageDescription, NSAppleEventsUsageDescription

CompanionWindows/                       — Windows "Hotspot Companion" (PoC; separate Node + .NET codebase)
├── backend/                            — .NET 8 worker: TetheringController (Mobile Hotspot AP+NAT), PipeServer (ACL'd named-pipe JSON-RPC)
├── app/                                — Electron UI: status + "Join from Vision Pro" panel (SSID / 8-char password / gateway IP)
├── spike/                              — Step-1 capability spike + SPIKE-FINDINGS.md (decision record)
└── README.md                           — build/run/architecture/protocol

VisionVNCTests/                         — app-hosted XCTest target (run locally, no CI)
├── TextDiffTests.swift                 — keyboard common-prefix diff
├── CompanionInjectProtocolTests.swift  — inject framing / drain / backspace
├── SavedConnectionEnvTests.swift       — SSH env parsing + name validation
└── LocalNetworkTests.swift             — Windows-ICS subnet inference for host auto-prefill

scripts/
├── setup-deps.sh                       — Clone+patch repos/ deps (local Moonlight builds)
├── build-and-sign.sh                   — Config-driven device build/sign/deploy (build-signing.conf, gitignored)
├── install-companion.sh                — Build the macOS companion + install to /Applications (quit/relaunch)
└── release.sh                          — Local Moonlight-enabled GitHub release (gh CLI)

ci/
├── deps/
│   ├── moonlight-common-c/Package.swift — SPM wrapper (MoonlightCommonC + enet targets)
│   └── opus/
│       ├── Package.swift               — SPM wrapper for Opus C library
│       ├── include/module.modulemap    — Exposes multistream API
│       └── spm-config/config.h         — Build configuration
├── patches/
│   ├── royalvnc-visionvnc.patch              — Static linking + VisionVNC API additions (KEEP IN SYNC with repos/royalvnc)
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
- **Compression/JPEG quality:** Configurable per connection via the local patch — `Settings(jpegQualityLevel:compressionLevel:)` (upstream hardcodes level 6)
- **Framebuffer pause:** `pauseFramebufferUpdates()` / `resumeFramebufferUpdates()` — local patch additions

## moonlight-common-c API Quick Reference

- **Session:** `LiStartConnection()` / `LiStopConnection()` — takes `SERVER_INFORMATION`, `STREAM_CONFIGURATION`, and callback structs
- **Callbacks:** `CONNECTION_LISTENER_CALLBACKS` (stage/connection events), `DECODER_RENDERER_CALLBACKS` (video), `AUDIO_RENDERER_CALLBACKS` (audio)
- **Video callback:** `drSubmitDecodeUnit(DECODE_UNIT*)` — linked list of `LENTRY` buffers containing Annex B H.264/HEVC NAL units or AV1 OBUs
- **Audio callback:** `arDecodeAndPlaySample(sampleData, sampleLength)` — Opus-encoded audio packets
- **Mouse:** `LiSendMouseMoveEvent(deltaX, deltaY)`, `LiSendMousePositionEvent(x, y, refWidth, refHeight)`, `LiSendMouseButtonEvent(action, button)`, `LiSendScrollEvent(direction)`
- **Keyboard:** `LiSendKeyboardEvent(keyAction, keyCode, modifiers)` — uses Windows VK codes, actions `KEY_ACTION_DOWN` (0x0801) / `KEY_ACTION_UP` (0x0802)
- **Gamepad:** `LiSendMultiControllerEvent(controllerNumber, activeGamepadMask, buttonFlags, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY)`
- **Stats:** `LiGetEstimatedRttInfo()` for network RTT; frame counts and decode timing tracked in `MoonlightVideoRenderer`
- **HDR:** `LiGetHdrMetadata(PSS_HDR_METADATA)` — retrieves mastering display and content light level info; `LiRequestIdrFrame()` — requests key frame after HDR mode change
- **Stage names:** STAGE_RTSP_HANDSHAKE, STAGE_CONTROL_STREAM, STAGE_VIDEO_STREAM, STAGE_AUDIO_STREAM, STAGE_INPUT_STREAM — surfaced via `LiGetStageName()`

## Known Constraints & Gotchas

### VNC
- **8-bit color depth is broken** with most modern VNC servers (including macOS Screen Sharing). It creates a palettized color map mode (`trueColor: false`) that Tight and ZRLE encodings reject. Low quality uses 16-bit instead.
- **RoyalVNCKit carries local modifications** — static linking (dyld crash fix), JPEG quality/compression settings, framebuffer pause/resume. The gitignored `repos/royalvnc` checkout is the working copy; the committed source of truth is `ci/patches/royalvnc-visionvnc.patch`. **Re-export the patch after any change to `repos/royalvnc`** (`cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-visionvnc.patch`), otherwise CI release builds break (this happened: VNCConnectionManager failed to compile against pristine upstream).

### Moonlight
- **C callbacks fire on background threads** — renderers use `nonisolated(unsafe)` globals and `@unchecked Sendable` conformance. Only one stream is active at a time; the bridge stores a global reference to the active manager/renderers.
- **CryptoManager builds X.509 certs from scratch** using ASN.1 DER helpers (no OpenSSL). The cert, private key (Keychain), and PKCS#12 are cached in UserDefaults. If the Keychain is reset, the client identity is regenerated and all servers must be re-paired.
- **NvHTTPClient uses NWConnection, not URLSession** — required for self-signed cert acceptance and mutual TLS. HTTP/1.1 is manually constructed. Responses are XML parsed with Foundation's `XMLParser`.
- **Server cert and UUID are stored in UserDefaults**, keyed per server — SwiftData doesn't handle raw `Data` blobs well for binary cert data.
- **Opus multistream decoder** requires channel count, stream count, coupled stream count, and channel mapping from the `OPUS_MULTISTREAM_CONFIGURATION` provided by moonlight-common-c. The decoder is always created even in muted mode (C API requirement), but AVAudioEngine is skipped.
- **Video renderer uses AVSampleBufferDisplayLayer** via `UIViewRepresentable` (`VideoLayerView`). The layer handles hardware decoding and display internally, including native HDR/EDR tone mapping. The custom UIView subclass overrides `layoutSubviews()` to keep the layer frame in sync — setting the frame in `makeUIView` alone doesn't work because `bounds` is zero at that point.
- **AV1 uses a custom OBU parser** (`BitstreamReader` + `parseAV1SequenceHeader`) to extract sequence headers for `CMVideoFormatDescription` creation. The parser implements AV1 spec Section 5.5 at bit granularity. AV1 config records (`av1C`) are built per ISO 14496-12.
- **HDR metadata uses raw memory access** to read `SS_HDR_METADATA` because Swift cannot directly access the anonymous struct array `displayPrimaries[3]` from the C header. The `packHdrMetadata` method reads fields at known offsets via `UnsafeRawPointer.bindMemory`. MDCV is packed in GBR order (not RGB) per the MDCV spec. Format description extension keys must use the proper CoreMedia constants (`kCMFormatDescriptionExtension_MasteringDisplayColorVolume`, `kCMFormatDescriptionExtension_ContentLightLevelInfo`) — lowercase string literals are silently ignored.
- **Audio FEC patches are required** — without the CI patches, moonlight-common-c crashes on FEC recovery with newer Sunshine versions. Always apply patches from `ci/patches/` when setting up the dependency.
- **Pairing supports two hash variants** — SHA-256 for server generation >= 7 (modern Sunshine), SHA-1 for older servers. The `NvPairingManager` auto-detects based on `/serverinfo` response.

### Audio Streaming
- **`ConnectionType.audio` is not gated** behind a compilation condition (unlike `.moonlight`) — it has no external dependencies.
- The macOS target shares the visionOS target's Swift settings (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); `Shared/` types are declared `nonisolated` so they're usable from audio/network threads in both targets.
- **The receiver has two session modes** (`AudioMode`, toggled in the mini player). **Speaker** (default): a **mixable** session (`.playback` + `.mixWithOthers`, spatial `.bypassed`, `setIsNowPlayingCandidate(true)`) — coexists with other apps/VoIP, never interrupts, and **auto-reloads** (fresh receiver) when another app grabs the audio config. It's ineligible for Now Playing/Control Center, so **don't add `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` to Speaker mode** — it would force an interrupting session. **Music**: an **exclusive** session (no `.mixWithOthers`) that *is* a Now Playing app — `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` map Control Center transport to the Mac's Music.app, and on interruption (a call) it **pauses the Mac source + local playback** (sends `.pause`) and resumes on `.shouldResume`, instead of reloading. The mode is passed into `AudioStreamReceiver`; changing it mid-stream rebuilds the receiver (the session category differs).
- **VoIP calls steal the audio session** (e.g. Google Meet in Safari): interruption *began* fires when the call starts (no ended/route-change until it finishes) and playback dies silently while TCP keeps flowing. Engine-only rebuilds do NOT recover — only a fresh receiver that re-asserts `setCategory`/`setActive` does. The receiver observes interruption (began+ended), `AVAudioEngineConfigurationChange`, and the silence-secondary-audio hint, and emits `.reloadRequested` → the manager reconnects immediately (loop guard: a second reload within 2 s falls back to backoff retry). Configure the session **once per receiver** — re-asserting it mid-call breaks the call's audio.
- **`setActive(true)` on every engine build** — after an interruption the session is deactivated; `engine.start()` alone reports running but pumps audio nowhere.
- **Apple Music streaming tracks expose no artwork** via the Music scripting interface (`artwork 1 of current track` is empty) — only local/downloaded files have it. The mini player falls back to the speaker status glyph; there is no public workaround.
- **Audio-session / window-lifecycle changes can only be verified on device** — build, then leave uncommitted for on-device testing before committing.

### Broadcast
- **visionOS strips the AVCapture surface**: no `AVCaptureAudioDataOutput` (mic uses an `AVAudioEngine` input tap), no session presets (device native format only), no `AVCaptureVideoPreviewLayer` (preview is an `AVSampleBufferDisplayLayer` fed raw capture frames marked `DisplayImmediately`).
- **"Mirror My View" is not a capture device** — it only reaches third-party code through a ReplayKit broadcast upload extension via the system View Sharing menu. Device discovery only ever returns the Persona "Front Camera".
- The extension bundle id `com.illixion.VisionVNC.broadcast` is hardcoded in `BroadcastShared.extensionBundleID` (used by `RPSystemBroadcastPickerView`) — keep in sync with the target's `PRODUCT_BUNDLE_IDENTIFIER`.
- Both the app and extension have `.entitlements` files with the `group.com.illixion.VisionVNC` App Group — but **the effective group is resolved at runtime** (`BroadcastShared.appGroup`): sideload re-signing (`build-and-sign.sh`) replaces entitlements with the provisioning profile's, whose group IDs we don't control, so both processes parse their `embedded.mobileprovision` and deterministically pick the same group (preferred if granted, else first sorted). The publish password keychain item uses `kSecAttrAccessGroup` = that group, with an ungrouped fallback for builds with no app-group entitlement (simulator).
- **`build-and-sign.sh` must never override `PRODUCT_BUNDLE_IDENTIFIER` on the xcodebuild command line** — command-line settings hit every target, cloning the app's ID onto the appex → installd `DuplicateIdentifier` (error 3002). The script patches each bundle's Info.plist after unpacking instead (app = `BUILD_BUNDLE_ID`, appex = `.broadcast` suffix), embeds the profile in both bundles, and signs the appex (inside-out) before the app.
- Tab-side capture pauses when the app loses foreground; the extension does not (separate process).
- **TLS**: a non-empty `broadcast.certFingerprint` (hex DER-SHA256, set by the pairing URL) switches `RTSPPublisher` to RTSPS with a custom `sec_protocol_options_set_verify_block` — system trust is fully replaced by the fingerprint match. The companion's managed mediamtx config is `rtspEncryption: strict`, so plain-RTSP clients can't connect to a companion-configured server.
- The companion's `BroadcastServerManager` shells out to `/usr/bin/openssl` (LibreSSL — RSA keygen for compat) and `brew services`; it requires the companion to be **unsandboxed** (it is) and mediamtx installed via brew (`/opt/homebrew` or `/usr/local` prefix).
- **"Add Sources to OBS"** (`OBSWebSocketClient`, obs-websocket v5 on `ws://127.0.0.1:4455`) provisions both Browser Sources in the current scene. The WebSocket password is picked up from the clipboard if the field is empty (the documented flow: OBS → Tools → WebSocket Server Settings → Show Connect Info → Copy Password; the user must press **Apply** after enabling the server or the password isn't saved) and persisted in UserDefaults on success. Source settings: `?controls=false&muted=false` URLs (a muted page produces **no** audio), `reroute_audio: true` (= the "Control audio via OBS" checkbox, required for mixer audio), `shutdown: true` (hidden sources release their WHEP connection). Layout is **enforced on every run** (existing sources get `SetInputSettings` + `SetSceneItemEnabled`/`SetSceneItemIndex`): camera on top + visible, view hidden — both are full-canvas and a dead WHEP page draws an opaque "stream not found" error that would cover the other source.

### SSH / Remote Claude / Companion Injection
- **macOS Keychain is unreachable over SSH** (it's bound to the GUI login session). So `claude` can't read its stored OAuth login in an SSH session. Fix: a `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) stored in the Vision Pro keychain (`KeychainStore`, per-connection) and injected per session. Claude Code reads env-var auth before the Keychain.
- **No `sshd_config` / `AcceptEnv` dependency** (rejected as macOS-update-fragile). The token is baked **inline** into the launch command by `SSHTerminalManager.claudeCommand`: `tmux set -gqa update-environment NAME; NAME=<tok> tmux new -A -d -s slug -c dir claude; exec tmux attach`. `exec` sheds the token-bearing argv within ms; `update-environment` makes it reach a pre-existing tmux server (session-scoped). macOS 11+ redacts a process's env from other non-root processes, but tmux holds it in the session env (queryable by same-uid `tmux show-environment`) — accepted; the win is no at-rest token on the Mac.
- **Secure Enclave key**: `SecureEnclaveSSHKey` (P-256, `ecdsa-sha2-nistp256`); falls back to a software P-256 key in the Keychain on the simulator. Host keys are accepted TOFU (pinning is a TODO in `SSHConnection.AcceptAllHostKeysDelegate`).
- **Companion text injection is text-only by design**: `Shared/CompanionInjectProtocol.swift` can express only `injectText` (UTF-8) and `injectBackspace` (count) — never key codes or modifiers — so a compromised channel can't synthesize Cmd+Space/Run-dialog payloads. Modifiers/special keys always use VNC keysyms. The channel is TLS-1.2-PSK on port 4856 via `CompanionInjectCrypto` (same companion token as audio, **domain-separated** HKDF so a leaked audio PSK ≠ inject PSK). The macOS server rejects loopback peers and needs Accessibility (`AXIsProcessTrusted`) + a default-off master toggle. `VNCConnectionManager.keyboardRoute` chooses companion vs VNC; it auto-falls-back to VNC when the channel is down.
- `SavedConnection.linkedCompanionConnectionID` (renamed from `linkedAudioConnectionID`, `@Attribute(originalName:)`) links a VNC connection to a companion (audio) connection — that one connection's host + token serves audio **and** injection.
- SSH sessions persist via tmux (`new -A`); a closed/wedged session is revived with `SSHSession.restart()` (Reconnect button) which replays the same launch.

### Logging
- visionOS app logs via `AppLog` (`os.Logger`, one category per component, `.line()` helper marks messages `.public` so OSLogStore shows them un-redacted — never use for secrets). `LogStore` polls the process-scoped OSLogStore (~1 s, viewer-refcounted, only while a Console view is visible) for the in-app Console tab/pop-out. The macOS sender uses local `os.Logger` instances (AppLog is visionOS-only).

### General
- **The project is arm64-only** (`ARCHS = arm64` in the project-level build configs). Caveat: SPM packages do NOT inherit project build settings, so `-destination 'generic/platform=visionOS Simulator'` still builds Opus for x86_64 and fails (`_Builtin_intrinsics.arm.neon` modulemap error — the spm-config presumes NEON). Use a concrete simulator destination (`platform=visionOS Simulator,name=Apple Vision Pro`, builds active arch only) or pass `ARCHS=arm64` on the xcodebuild command line (overrides apply to packages too).
- **SwiftData migrations** require default values on all new non-optional properties and `@Attribute(originalName:)` for renamed columns, or the store fails to load (CoreData error 134110).
- **`navigationTitle` requires `NavigationStack`** on visionOS — without it, the title bar doesn't render.
- **`dismissWindow(id:)`** is the correct API for closing `WindowGroup` windows on visionOS, not `dismiss()`.
- **`UIKey.characters`** is `String` (non-optional) in this SDK version, not `String?`. Use `.isEmpty` checks instead of optional binding.
