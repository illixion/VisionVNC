# Moonlight Game Streaming — Implementation Plan

## Decision: Port Protocol Into VisionVNC (Approach B)

Compiling Moonlight iOS for visionOS would require gutting the entire UIKit/Storyboard UI and rewriting it — effectively 70% of the app. We already have a working visionOS app with SwiftUI multi-window architecture, CADisplayLink rendering, gesture translation, and hardware keyboard capture. The Moonlight protocol layer (moonlight-common-c) is a clean C library with zero platform dependencies. We integrate it the same way we integrated RoyalVNCKit: as a local dependency with a Swift bridge.

---

## Architecture Overview

```
VisionVNC App
├── VNC path (existing)
│   └── VNCConnectionManager → RoyalVNCKit
│
├── Moonlight path (new)
│   ├── MoonlightConnectionManager → moonlight-common-c (C callbacks)
│   ├── MoonlightVideoRenderer     → AVSampleBufferDisplayLayer
│   ├── MoonlightAudioRenderer     → AVAudioEngine + Opus
│   ├── NvHTTPClient               → GameStream HTTP API
│   └── NvPairingManager           → OpenSSL challenge-response
│
├── Shared
│   ├── RemoteDesktopView (already protocol-agnostic — reads CGImage)
│   ├── GestureTranslator (coordinate mapping)
│   ├── HardwareKeyboardView (key capture)
│   └── SavedConnection (SwiftData, extended with connection type)
```

The existing `RemoteDesktopView` reads `framebufferImage: CGImage?` and `framebufferSize: CGSize` from the connection manager and renders them. It doesn't know anything about VNC. If `MoonlightConnectionManager` exposes the same observable properties, the view works as-is.

---

## Phase 0: Dependencies & Build Setup

### 0.1 Initialize moonlight-common-c

The submodule in moonlight-ios is empty. Options:
- **Option A**: Clone moonlight-common-c standalone into `repos/moonlight-common-c/`
  - Repository: `https://github.com/moonlight-stream/moonlight-common-c`
- **Option B**: Initialize the submodule inside moonlight-ios: `cd repos/moonlight-ios && git submodule update --init --recursive`

Wrap it as a local SPM package (like we did with RoyalVNCKit):

```
repos/moonlight-common-c/
├── Package.swift          ← we create this
├── Sources/
│   └── MoonlightCommonC/
│       ├── include/       ← public headers (Limelight.h, etc.)
│       └── src/           ← C source files
```

The Package.swift exposes it as a C target:

```swift
// Package.swift
let package = Package(
    name: "MoonlightCommonC",
    products: [
        .library(name: "MoonlightCommonC", type: .static, targets: ["MoonlightCommonC"])
    ],
    targets: [
        .target(
            name: "MoonlightCommonC",
            path: ".",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("reedsolomon")
            ]
        )
    ]
)
```

### 0.2 Opus Audio Codec

Options (pick one):
- **SPM wrapper**: Find or create an SPM package around the Opus C source (libopus is ~50 .c files, BSD license)
- **System library**: Use a prebuilt xcframework

Recommended: SPM C target wrapping Opus source, same pattern as moonlight-common-c. The Moonlight iOS repo has a build script at `repos/moonlight-ios/BuildScripts/build-libopus.sh` for reference.

### 0.3 OpenSSL

Already an SPM dependency in moonlight-ios. The same package (`apple/swift-crypto` or a direct OpenSSL SPM package) likely supports visionOS. Needed for:
- Pairing handshake (X.509 certs, RSA encryption, AES-128-ECB)
- RTSP stream encryption

### 0.4 FFmpeg (Optional / Deferred)

FFmpeg is only needed for **AV1 bitstream parsing** (sequence header extraction). H.264 and HEVC work without it — `VideoToolbox` handles them natively via `CMSampleBuffer`. We can skip AV1 initially and add FFmpeg later if needed.

### 0.5 SDL2 (Skip)

Moonlight uses SDL2 for audio playback. We'll use `AVAudioEngine` instead — it's native, supports visionOS, and avoids a large C dependency.

### 0.6 Add Dependencies to Xcode Project

Add local SPM package references in Xcode:
- `repos/moonlight-common-c` → MoonlightCommonC
- `repos/opus` (or wherever we set it up) → Opus

Same approach as the existing RoyalVNCKit local package reference.

---

## Phase 1: Data Model & App Routing

### 1.1 Extend SavedConnection

Add connection type discrimination and Moonlight-specific fields:

```swift
// Models/SavedConnection.swift

enum ConnectionType: String, Codable {
    case vnc
    case moonlight
}

// New properties on SavedConnection:
var connectionType: ConnectionType = .vnc

// Moonlight-specific (optional, only used when connectionType == .moonlight)
var moonlightUUID: String?              // Sunshine server UUID (from /serverinfo)
var moonlightServerCert: Data?          // Pinned server certificate (after pairing)

// Stream quality
var moonlightBitrate: Int = 20000       // kbps, default 20 Mbps
var moonlightFPS: Int = 60              // 30, 60, 120
var moonlightResolutionWidth: Int = 1920
var moonlightResolutionHeight: Int = 1080
var moonlightVideoCodec: VideoCodecPreference = .auto
var moonlightEnableHDR: Bool = false

// Frame delivery
var moonlightUseFramePacing: Bool = false   // false = lowest latency, true = smoothest video

// Audio
var moonlightAudioConfig: AudioConfiguration = .stereo  // stereo, surround51, surround71
var moonlightPlayAudioOnPC: Bool = false                 // also play audio on host

// Input
var moonlightTouchMode: TouchMode = .relative            // relative (cursor) vs absolute (direct)
var moonlightMultiController: Bool = true                // auto-detect multiple gamepads
var moonlightSwapABXY: Bool = false                      // swap A/B and X/Y buttons

// Server-side
var moonlightOptimizeGameSettings: Bool = true           // let Sunshine optimize game settings

// Debug
var moonlightShowStatsOverlay: Bool = false              // network/decode/render stats
```

**SwiftData migration**: All new properties must have defaults or be optional. Use `@Attribute(originalName:)` if renaming anything (per CLAUDE.md gotcha).

### 1.2 Add Supporting Enums

```swift
enum VideoCodecPreference: String, Codable {
    case auto       // let server/client negotiate best option
    case h264
    case hevc
    case av1        // future — requires FFmpeg for bitstream parsing
}

enum AudioConfiguration: String, Codable {
    case stereo     // AUDIO_CONFIGURATION_STEREO (2ch)
    case surround51 // AUDIO_CONFIGURATION_51_SURROUND (6ch)
    case surround71 // AUDIO_CONFIGURATION_71_SURROUND (8ch)
}

enum TouchMode: String, Codable {
    case relative   // cursor-based, deltas — default for games
    case absolute   // direct screen coordinate mapping — for desktop use
}
```

### 1.3 Bitrate Auto-Calculation

Moonlight iOS auto-adjusts bitrate when resolution or FPS changes. Port this logic:

```swift
// Default bitrate table (kbps) indexed by resolution tier
// Moonlight iOS slider values: 500, 1000, 1500, 2000, 2500, 3000, 4000, 5000,
//   6000, 7000, 8000, 9000, 10000, 12000, 15000, 18000, 20000, 30000, 40000,
//   50000, 60000, 70000, 80000, 100000, 120000, 150000

static func suggestedBitrate(width: Int, height: Int, fps: Int) -> Int {
    let pixels = width * height
    let base: Int
    switch pixels {
    case ..<(921_600):   base = 5000    // 720p → 5 Mbps
    case ..<(2_073_600): base = 10000   // 1080p → 10 Mbps
    case ..<(3_686_400): base = 20000   // 1440p → 20 Mbps
    default:             base = 40000   // 4K → 40 Mbps
    }
    return fps > 60 ? base * 2 : (fps > 30 ? base : base / 2)
}
```

### 1.3 Route by Connection Type in ConnectionListView

When user taps a saved connection:
- If `.vnc` → existing flow via `VNCConnectionManager`
- If `.moonlight` → new flow via `MoonlightConnectionManager`

Both managers are injected via `.environment()` in VisionVNCApp.swift.

### 1.5 Add Moonlight Form Fields

Extend `ConnectionFormView` with a connection type picker and conditional Moonlight fields:

**Video section:**
- Resolution picker: 640x360, 720p, 1080p (default), 1440p, 4K, Custom (min 256, max 8192 for HEVC/4096 for H.264)
- FPS picker: 30, 60 (default), 120
- Bitrate slider: 0.5–150 Mbps (auto-calculated default based on resolution/fps, user can override)
- Codec picker: Auto (default), H.264, HEVC, AV1 (greyed out if hardware decode unavailable — check `VTIsHardwareDecodeSupported()`)
- HDR toggle (only enabled if HEVC supported + device supports HDR10)
- Frame pacing: "Lowest Latency" (default) / "Smoothest Video"

**Audio section:**
- Audio config: Stereo (default), 5.1 Surround, 7.1 Surround
- Play audio on host PC toggle

**Input section:**
- Touch mode: Relative/Cursor (default) / Absolute/Direct
- Multi-controller toggle (default on)
- Swap A/B X/Y buttons toggle (default off)

**Server section:**
- Optimize game settings toggle (default on)

**Debug section:**
- Statistics overlay toggle (default off)

---

## Phase 2: GameStream HTTP Client (NvHTTPClient)

This is independent of the streaming protocol — it's pure HTTP/HTTPS communication with the Sunshine server for discovery, pairing, and app management.

### 2.1 NvHTTPClient

**Reference**: `repos/moonlight-qt/app/backend/nvhttp.h` and `nvhttp.cpp`

```swift
// Networking/NvHTTPClient.swift

actor NvHTTPClient {
    let baseURL: URL           // https://{hostname}:47984
    let clientCert: SecIdentity // Our client TLS certificate
    
    // Server info
    func getServerInfo() async throws -> ServerInfo
    
    // App management
    func getAppList() async throws -> [MoonlightApp]
    func launchApp(appId: Int, config: StreamConfig) async throws -> LaunchResult
    func quitApp() async throws
    
    // Pairing
    func getServerCert() async throws -> SecCertificate
}
```

**Endpoints** (from Sunshine/moonlight-qt):
| Endpoint | Purpose |
|----------|---------|
| `GET /serverinfo` | Server capabilities, GFE version, current game, codec support |
| `GET /applist` | Available games/apps (id, name, isRunning) |
| `GET /launch?appid=X&mode=WxHxFPS&...` | Start streaming an app |
| `GET /resume` | Resume a suspended session |
| `GET /cancel` | Cancel/quit running app |
| `GET /pair?...` | Pairing handshake phases |

**ServerInfo model**:
```swift
struct ServerInfo {
    let hostname: String
    let mac: String
    let uuid: String
    let gfeVersion: String
    let appVersion: String
    let currentGame: Int          // 0 = nothing running
    let serverCodecModeSupport: Int // bitmask for H264/HEVC/AV1
    let maxLumaPixelsHEVC: Int
    let serverCapabilities: Int
}
```

Uses `XMLParser` to parse the XML responses (all GameStream HTTP responses are XML).

### 2.2 NvPairingManager

**Reference**: `repos/moonlight-qt/app/backend/nvpairingmanager.h` and `.cpp`

The pairing flow is a multi-step challenge-response using OpenSSL:

1. **Generate client certificate** (self-signed X.509, RSA 2048)
2. **GET /pair?phrase=getservercert&clientcert=...** → receive server cert
3. **Generate random PIN** (4 digits, displayed to user)
4. **Derive shared secret** from PIN + server cert signature
5. **AES-128-ECB encrypt** client challenge with derived key
6. **GET /pair?phrase=clientchallenge&clientchallenge=...** → server challenge response
7. **Verify server response**, send client pairing secret
8. **GET /pair?phrase=clientpairingsecret&clientpairingsecret=...** → confirmation

```swift
// Networking/NvPairingManager.swift

actor NvPairingManager {
    enum PairResult {
        case success(serverCert: Data)
        case pinRejected
        case failed(Error)
        case alreadyInProgress
    }
    
    func pair(with client: NvHTTPClient, pin: String) async throws -> PairResult
    
    // Internal: generates/loads persistent client identity (stored in Keychain)
    func getOrCreateClientIdentity() throws -> SecIdentity
}
```

**Client certificate persistence**: Store in Keychain. One identity per app installation, reused across all paired servers.

---

## Phase 3: Moonlight Connection Manager

### 3.1 MoonlightConnectionManager

**Reference**: `repos/moonlight-qt/app/streaming/session.h` and `session.cpp`

This is the core bridge between moonlight-common-c and SwiftUI — structurally parallel to `VNCConnectionManager`.

```swift
// ViewModels/MoonlightConnectionManager.swift

@preconcurrency import MoonlightCommonC

@Observable
class MoonlightConnectionManager: NSObject {
    // Published state (same interface as VNCConnectionManager)
    var connectionState: AppConnectionState = .idle
    var framebufferImage: CGImage?
    var framebufferSize: CGSize = .zero
    var statusMessage: String = ""
    
    // Moonlight-specific
    var currentApp: MoonlightApp?
    var streamStats: StreamStats?
    
    // Components
    private var videoRenderer: MoonlightVideoRenderer?
    private var audioRenderer: MoonlightAudioRenderer?
    private var displayLink: CADisplayLink?
    
    func connect(to server: SavedConnection, appId: Int) { ... }
    func disconnect() { ... }
    
    // Input forwarding
    func sendMouseMove(deltaX: Float, deltaY: Float) { ... }
    func sendMouseButton(button: Int, pressed: Bool) { ... }
    func sendKeyboardEvent(keyCode: Int16, modifiers: Int32, pressed: Bool) { ... }
    func sendGamepadState(...) { ... }  // future: GameController framework
}
```

### 3.2 C Callback Bridge

moonlight-common-c uses static C function callbacks. The pattern for bridging to Swift:

```swift
// Store a global pointer to the active manager (only one stream at a time)
private var activeMoonlightManager: MoonlightConnectionManager?

// Connection callbacks
private let connectionCallbacks: CONNECTION_LISTENER_CALLBACKS = {
    var cb = CONNECTION_LISTENER_CALLBACKS()
    cb.stageStarting = { stage in
        Task { @MainActor in
            activeMoonlightManager?.handleStageStarting(stage)
        }
    }
    cb.connectionStarted = {
        Task { @MainActor in
            activeMoonlightManager?.handleConnectionStarted()
        }
    }
    cb.connectionTerminated = { errorCode in
        Task { @MainActor in
            activeMoonlightManager?.handleConnectionTerminated(errorCode)
        }
    }
    // ... etc
    return cb
}()
```

### 3.3 Connection Flow

```
1. MoonlightConnectionManager.connect(to:appId:)

2. Build STREAM_CONFIGURATION from SavedConnection settings:
   - width, height ← moonlightResolutionWidth/Height
   - fps ← moonlightFPS
   - bitrate ← moonlightBitrate
   - audioConfiguration ← moonlightAudioConfig → AUDIO_CONFIGURATION_* constant
   - supportedVideoFormats ← moonlightVideoCodec preference + moonlightEnableHDR
     (auto = negotiate best; filter by VTIsHardwareDecodeSupported)
   - Generate random AES key/IV for input encryption (RAND_bytes)

3. Launch app via NvHTTPClient:
   - GET /launch?appid=X&mode=WxHxFPS&additionalStates=1
     &sops={optimizeGameSettings}&rikey=...&rikeyid=...
     &localAudioPlayMode={playAudioOnPC ? 1 : 0}
   - Check response for session URL

4. Build SERVER_INFORMATION from saved server info + launch response
5. Register callbacks (connection, video, audio)
6. Call LiStartConnection() on background thread
7. Callbacks fire → marshal to @MainActor → update observable state
8. Video frames arrive via drSubmitDecodeUnit → MoonlightVideoRenderer
   - Frame pacing mode determined by moonlightUseFramePacing
9. Audio samples arrive via arDecodeAndPlaySample → MoonlightAudioRenderer
10. Input forwarding uses moonlightTouchMode to select relative vs absolute mouse
```

### 3.4 Connection Stage Names

moonlight-common-c reports stages: Resolving → Handshake → RTSP → Control → Video → Audio → Input. Surface these in `statusMessage` using `LiGetStageName()`.

---

## Phase 4: Video Rendering

### 4.1 MoonlightVideoRenderer

**Reference**: `repos/moonlight-ios/Limelight/Stream/VideoDecoderRenderer.m`

Uses `AVSampleBufferDisplayLayer` for hardware-accelerated H.264/HEVC decoding. This is the same approach Moonlight iOS uses and should work on visionOS.

```swift
// Streaming/MoonlightVideoRenderer.swift

class MoonlightVideoRenderer {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    
    // Called from C callback (drSetup)
    func setup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) { ... }
    
    // Called from C callback (drSubmitDecodeUnit)  
    func submitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        // 1. Extract NAL units from linked list in DECODE_UNIT
        // 2. Detect SPS/PPS/VPS parameter sets → CMVideoFormatDescription
        // 3. Wrap picture data in CMBlockBuffer
        // 4. Create CMSampleBuffer with timing info
        // 5. Enqueue on displayLayer
        return DR_OK
    }
}
```

**NAL unit processing** (H.264/HEVC):
- Parameter sets (SPS, PPS, VPS) → `CMVideoFormatDescriptionCreateFromH264ParameterSets` / `CreateFromHEVCParameterSets`
- Picture data → `CMBlockBuffer` → `CMSampleBuffer` → `AVSampleBufferDisplayLayer.enqueue()`

**Integration with RemoteDesktopView**:

Two options:
- **Option A**: Wrap `AVSampleBufferDisplayLayer` in a `UIViewRepresentable` and use it directly (better latency, hardware compositing)
- **Option B**: Periodically snapshot the layer to `CGImage` and feed it through the existing `framebufferImage` path (simpler integration, slightly more overhead)

**Recommended**: Option A for the stream view, with a new `MoonlightStreamView` that wraps the display layer. The existing `RemoteDesktopView` can conditionally use either the CGImage path (VNC) or the display layer view (Moonlight).

### 4.2 Frame Pacing

Controlled by `moonlightUseFramePacing` setting — two modes:

**Lowest Latency (default, `useFramePacing = false`):**
- Enqueue frames on `AVSampleBufferDisplayLayer` immediately as they arrive from `drSubmitDecodeUnit`
- No display link gating — the layer composites on the next display refresh
- Frames may arrive mid-refresh causing minor tearing, but minimizes input-to-photon delay
- Best for competitive/fast-paced games

**Smoothest Video (`useFramePacing = true`):**
- Use `CADisplayLink` to gate frame presentation
- Set `preferredFrameRateRange` to match stream FPS (30/60/120)
- Buffer one frame and present it aligned to display vsync via `CMSampleBuffer` presentation timestamps
- Drop late frames to maintain sync
- Better for cinematic games, video playback, desktop streaming

**Reference**: Moonlight iOS `VideoDecoderRenderer.m` — checks `>90%` match between stream FPS and display refresh rate to decide frame pacing strategy.

### 4.3 HDR Support (Future)

Moonlight supports HDR10 via HEVC Main 10 / AV1 Main 10. On visionOS, this would require:
- `CMVideoFormatDescription` with HDR metadata (mastering display, content light level)
- EDR rendering via `CAMetalLayer` or display layer HDR properties
- Deferred — get SDR working first

---

## Phase 5: Audio Rendering

### 5.1 MoonlightAudioRenderer

**Reference**: `repos/moonlight-qt/app/streaming/audio/audio.cpp`

```swift
// Streaming/MoonlightAudioRenderer.swift

class MoonlightAudioRenderer {
    private var opusDecoder: OpaquePointer?  // opus_multistream_decoder
    private var audioEngine: AVAudioEngine
    private var playerNode: AVAudioPlayerNode
    private var audioFormat: AVAudioFormat
    
    // Called from C callback (arInit)
    func initialize(config: UnsafePointer<OPUS_MULTISTREAM_CONFIGURATION>) {
        // 1. Create opus_multistream_decoder with channel mapping from config
        //    - config contains: sampleRate, channelCount, streams, coupledStreams, mapping[]
        // 2. Configure AVAudioEngine format to match:
        //    - Stereo: 2ch, 48kHz
        //    - 5.1: 6ch, 48kHz (requires channel layout remapping — Opus order ≠ CoreAudio order)
        //    - 7.1: 8ch, 48kHz
        // 3. Start audio engine
    }
    
    // Called from C callback (arDecodeAndPlaySample)
    func decodeAndPlay(sampleData: UnsafePointer<CChar>, sampleLength: Int32) {
        // 1. Decode Opus → PCM with opus_multistream_decode() (Int16) or _float() (Float32)
        // 2. Wrap in AVAudioPCMBuffer
        // 3. Schedule on playerNode
        // 4. Backpressure: if queued audio exceeds ~200ms, drop oldest buffers
    }
    
    func cleanup() { ... }
}
```

**Audio configuration** maps from `moonlightAudioConfig` setting:
```swift
// In STREAM_CONFIGURATION setup:
switch savedConnection.moonlightAudioConfig {
case .stereo:     streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO
case .surround51: streamConfig.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND
case .surround71: streamConfig.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND
}

// playAudioOnPC flag is passed in the /launch HTTP request, not in STREAM_CONFIGURATION
```

**AVAudioSession configuration**:
```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playback, options: .mixWithOthers)
try session.setActive(true)
```

**Channel remapping note**: Opus uses Vorbis channel order (FL, FC, FR, ...) while CoreAudio uses SMPTE/ITU order (FL, FR, FC, ...). For surround configs, remap channels after decode — see `IAudioRenderer::remapChannels()` in moonlight-qt.

---

## Phase 6: Input Forwarding

### 6.1 Mouse/Pointer Input

Map existing gesture infrastructure to Moonlight input API:

```swift
// Moonlight uses relative mouse by default for games
LiSendMouseMoveEvent(deltaX, deltaY)
LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT)
LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
LiSendScrollEvent(SCROLL_UP / SCROLL_DOWN)
```

The existing `GestureTranslator` does absolute coordinate mapping (VNC-style). For Moonlight games, we need **relative mouse mode** (deltas). Add a relative mode to gesture handling or use a separate gesture handler for the Moonlight stream view.

For non-game apps streamed via Moonlight, absolute positioning may be useful — Moonlight supports `LiSendMousePositionEvent(x, y, referenceWidth, referenceHeight)`.

### 6.2 Keyboard Input

Reuse `HardwareKeyboardView` (UIKeyboardHIDUsage capture). Map to Moonlight key events:

```swift
// Moonlight uses Windows virtual key codes (not X11 KeySyms like VNC)
LiSendKeyboardEvent(0x8001, keyCode, modifiers)  // key down
LiSendKeyboardEvent(0x8002, keyCode, modifiers)  // key up
```

Need a mapping table: `UIKeyboardHIDUsage` → Windows VK codes (different from the VNC X11 KeySym mapping).

**Reference**: `repos/moonlight-qt/app/streaming/input/keyboard.cpp` for the SDL→VK mapping.

### 6.3 Gamepad Input (Future)

Use Apple's `GameController` framework to detect connected controllers:

```swift
import GameController

GCController.startWirelessControllerDiscovery()
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, ...)

// Map to Moonlight multi-controller input
LiSendMultiControllerEvent(controllerNumber, activeGamepadMask,
    buttonFlags, leftTrigger, rightTrigger,
    leftStickX, leftStickY, rightStickX, rightStickY)
```

This is a natural fit for visionOS — Bluetooth gamepads (DualSense, Xbox) are supported.

---

## Phase 7: UI Integration

### 7.1 Server Discovery

Add mDNS/Bonjour browser for automatic Sunshine server discovery:

```swift
// Networking/MoonlightServerBrowser.swift

class MoonlightServerBrowser: NSObject, NetServiceBrowserDelegate {
    private let browser = NetServiceBrowser()
    // Sunshine advertises _nvstream._tcp
    func startBrowsing() {
        browser.searchForServices(ofType: "_nvstream._tcp.", inDomain: "")
    }
}
```

Display discovered servers in `ConnectionListView` with an "Add Moonlight Server" section or auto-discovery list.

### 7.2 Pairing Flow UI

When connecting to an unpaired server:
1. Show a sheet with a 4-digit PIN
2. User enters PIN in Sunshine web UI (or it auto-displays)
3. Pairing completes → save server cert to `SavedConnection`

### 7.3 App Picker

After pairing, before streaming:
1. Fetch app list via `NvHTTPClient.getAppList()`
2. Show grid/list of available apps (with box art)
3. User selects app → launch stream
4. Or "Desktop" option to stream full desktop

### 7.4 Stream View

Either extend `RemoteDesktopView` or create `MoonlightStreamView`:
- `AVSampleBufferDisplayLayer` wrapped in `UIViewRepresentable`
- Overlay controls: disconnect, keyboard toggle, settings
- Gesture handling configured for relative mouse (games) or absolute (desktop) based on `moonlightTouchMode`

### 7.6 Statistics Overlay

When `moonlightShowStatsOverlay` is enabled, render a semi-transparent HUD showing real-time streaming diagnostics:

```swift
struct StreamStatsOverlay: View {
    let stats: StreamStats  // populated from moonlight-common-c VIDEO_STATS + custom timing
    
    // Display:
    // - Network latency (RTT ms)
    // - Decode time (ms per frame)
    // - Render time (ms per frame)  
    // - Frame rate (actual FPS vs target)
    // - Bitrate (actual Mbps)
    // - Codec in use (H.264/HEVC/AV1)
    // - Resolution
    // - Frames dropped / lost
    // - Network jitter
}
```

**Data sources:**
- `LiGetEstimatedRttInfo()` — round-trip time
- `VIDEO_STATS` struct from moonlight-common-c — frame counts, decode stats
- Custom timing around `drSubmitDecodeUnit` → display for decode/render latency
- Audio buffer level for audio sync status

Position: top-left corner, monospace font, low opacity — same style as Moonlight iOS overlay.

### 7.5 Connection List Changes

```
ConnectionListView
├── Section: VNC Servers (existing)
│   └── [saved VNC connections]
├── Section: Moonlight Servers
│   ├── [discovered/saved Moonlight servers]
│   └── "Add Server Manually" button
```

---

## Phase 8: Stretch Goals

| Feature | Depends On | Notes |
|---------|-----------|-------|
| AV1 codec support | FFmpeg visionOS build | Only needed for AV1 sequence header parsing |
| HDR streaming | Phase 4 HDR | HEVC Main 10 / AV1 Main 10 + EDR rendering |
| Gamepad support | Phase 6.3 | GameController framework, rumble via CoreHaptics |
| Adaptive bitrate | StreamStats from moonlight-common-c | Dynamic quality adjustment based on network conditions |
| Custom resolution | Phase 1 form | User-specified WxH (min 256, max 4096 H.264 / 8192 HEVC) |
| Multi-display | visionOS window management | Stream to separate virtual displays |
| Spatial rendering | RealityKit | Curved screen or volumetric display |
| 120 FPS | Device capability check | Only offer if display supports >62 Hz refresh |

---

## Implementation Order

The phases above are roughly dependency-ordered. Suggested sprint breakdown:

### Sprint 1: Foundation
- [ ] Phase 0: Set up moonlight-common-c + Opus as local SPM packages
- [ ] Phase 0: Verify they compile for visionOS simulator
- [ ] Phase 1: Extend SavedConnection model with all Moonlight settings fields
- [ ] Phase 1: Add supporting enums (VideoCodecPreference, AudioConfiguration, TouchMode)
- [ ] Phase 1: Add connection type routing in ConnectionListView

### Sprint 2: Server Communication
- [ ] Phase 2.1: NvHTTPClient — serverinfo, applist, launch/quit
- [ ] Phase 2.2: NvPairingManager — full pairing handshake
- [ ] Phase 7.1: Basic server discovery (mDNS)
- [ ] Phase 7.2: Pairing flow UI

### Sprint 3: Streaming Core
- [ ] Phase 3: MoonlightConnectionManager with C callback bridge
- [ ] Phase 3: Wire all SavedConnection settings → STREAM_CONFIGURATION + /launch params
- [ ] Phase 4: Video renderer (H.264/HEVC via AVSampleBufferDisplayLayer)
- [ ] Phase 4: Frame pacing (both lowest-latency and smoothest-video modes)
- [ ] Phase 5: Audio renderer (Opus → AVAudioEngine, stereo + surround channel remapping)
- [ ] Get a basic stream working end-to-end

### Sprint 4: Input & Polish
- [ ] Phase 6.1: Mouse input (relative + absolute modes based on touchMode setting)
- [ ] Phase 6.2: Keyboard input with Windows VK code mapping
- [ ] Phase 7.3: App picker UI
- [ ] Phase 7.4: Stream view with controls
- [ ] Phase 7.5: Unified connection list
- [ ] Phase 7.6: Statistics overlay (network, decode, render, FPS, bitrate, codec, drops)
- [ ] Phase 1.5: Moonlight settings form (resolution, FPS, bitrate slider, codec, HDR, frame pacing, audio, input, debug)
- [ ] Bitrate auto-calculation when resolution/FPS changes

### Sprint 5: Stretch
- [ ] Phase 6.3: Gamepad support (GameController framework, multi-controller, A/B X/Y swap, rumble)
- [ ] Phase 8: HDR, AV1, custom resolution, 120 FPS, spatial rendering

---

## Key Reference Files

When implementing, reference these files from the cloned repos:

| Component | Moonlight-Qt Reference | Moonlight-iOS Reference |
|-----------|----------------------|------------------------|
| Session/connection | `repos/moonlight-qt/app/streaming/session.cpp` | `repos/moonlight-ios/Limelight/Stream/Connection.m` |
| Video decoder | `repos/moonlight-qt/app/streaming/video/ffmpeg.cpp` | `repos/moonlight-ios/Limelight/Stream/VideoDecoderRenderer.m` |
| Audio renderer | `repos/moonlight-qt/app/streaming/audio/audio.cpp` | `repos/moonlight-ios/Limelight/Stream/Connection.m` (lines 190-288) |
| HTTP client | `repos/moonlight-qt/app/backend/nvhttp.cpp` | `repos/moonlight-ios/Limelight/Network/HttpManager.m` |
| Pairing | `repos/moonlight-qt/app/backend/nvpairingmanager.cpp` | `repos/moonlight-ios/Limelight/Crypto/CryptoManager.m` |
| Host model | `repos/moonlight-qt/app/backend/nvcomputer.h` | `repos/moonlight-ios/Limelight/Database/TemporaryHost.h` |
| Keyboard mapping | `repos/moonlight-qt/app/streaming/input/keyboard.cpp` | `repos/moonlight-ios/Limelight/Input/KeyboardSupport.m` |
| Server discovery | `repos/moonlight-qt/app/backend/computermanager.cpp` | `repos/moonlight-ios/Limelight/Network/DiscoveryManager.m` |
| moonlight-common-c API | `repos/moonlight-qt/moonlight-common-c/src/Limelight.h` | (submodule empty — use Qt's copy) |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| moonlight-common-c won't compile for visionOS | Blocker | It's pure C with POSIX sockets — should be fine. Test early in Phase 0. |
| AVSampleBufferDisplayLayer behaves differently on visionOS | High | Test with a simple H.264 file first. Fallback: Metal rendering with VideoToolbox decompression session. |
| OpenSSL SPM package doesn't support visionOS | Medium | Use swift-crypto for AES/RSA, or build OpenSSL from source with visionOS SDK. |
| Opus SPM build fails | Medium | Opus is portable C. If SPM is tricky, use a prebuilt xcframework. |
| Latency too high for gaming | Medium | Use AVSampleBufferDisplayLayer (hardware path), skip CGImage conversion. Optimize audio buffer sizes. |
| Pairing protocol complexity | Medium | Well-documented in moonlight-qt. Port step-by-step from nvpairingmanager.cpp. |
