# VisionVNC

A native remote desktop and game streaming app for Apple Vision Pro, built in Swift with SwiftUI.

VisionVNC combines a full-featured **VNC viewer** with a **Moonlight game streaming** client in a single visionOS app. Connect to any VNC server for remote desktop access, or stream games and applications from a [Sunshine](https://github.com/LizardByte/Sunshine) / NVIDIA GameStream host with hardware-accelerated video decoding and low-latency input.

## Features

### VNC Remote Desktop
- Connect to any VNC server on your local network
- Auto-login with saved credentials (VNC password and macOS Screen Sharing username/password auth)
- Hardware and Bluetooth keyboard support with full key mapping
- On-screen soft keyboard with modifier keys, function keys, and arrow keys
- Configurable quality presets (Low/Medium/High) with JPEG quality, compression level, and color depth tuning
- Trackpad Only mode — transparent input overlay for use on top of Mac Virtual Display

### Moonlight Game Streaming
- Stream games and desktop from a [Sunshine](https://github.com/LizardByte/Sunshine) or NVIDIA GameStream host
- Hardware-accelerated H.264, HEVC, and AV1 decoding via AVSampleBufferDisplayLayer
- HDR10 support with automatic tone mapping (HEVC Main 10 / AV1 Main 10 with PQ transfer function)
- Opus audio with stereo, 5.1, and 7.1 surround sound support
- Configurable resolution (720p to 4K), frame rate (30/60/120 FPS), and bitrate (0.5-150 Mbps)
- Bluetooth gamepad support (DualSense, Xbox, and more) with up to 4 controllers
- Relative mouse mode for games and absolute mode for desktop use
- Hardware and soft keyboard with Windows virtual key code mapping
- Live streaming statistics overlay (codec, FPS, RTT, decode time, dropped frames)
- PIN-based pairing with Sunshine servers (SHA-256 and legacy SHA-1)
- Session management — disconnect locally or quit the app on the server

### Audio Streaming
- Stream bit-exact, uncompressed system audio from your Mac via the bundled **VisionVNC Audio Sender** menu bar app (separate macOS target in this project)
- Works around macOS forcing Spatial Audio on for Mac Virtual Display audio — playback through VisionVNC honors the per-app Spatial Audio setting
- Captures system audio with a Core Audio process tap — no virtual audio driver (BlackHole etc.) required
- Optional "Mute Mac output while streaming" so audio plays only through the Vision Pro
- Float32 PCM over TCP on the local network (~3 Mbps for stereo 48 kHz), no lossy codec in the chain

### Shared
- Multi-window interface — remote desktop, stream view, keyboard, and server list as separate visionOS windows
- Saved connections with SwiftData persistence
- Per-connection settings for both VNC and Moonlight

## Requirements

- Apple Vision Pro or visionOS Simulator
- visionOS 26.0+
- Xcode 26.0+

## Setup

### VNC Dependencies

VisionVNC uses [RoyalVNCKit](https://github.com/royalapplications/royalvnc) for the VNC protocol implementation.

1. Clone this repository:
   ```bash
   git clone https://github.com/Illixion/VisionVNC.git
   cd VisionVNC
   ```

2. Clone the RoyalVNCKit dependency:
   ```bash
   mkdir -p repos
   git clone https://github.com/royalapplications/royalvnc.git repos/royalvnc
   ```

3. Change the RoyalVNCKit library type to static in `repos/royalvnc/Package.swift`:
   ```swift
   // Change .dynamic to .static
   .library(name: "RoyalVNCKit", type: .static, targets: ["RoyalVNCKit"]),
   ```

4. Apply the configurable quality patch:
   ```bash
   cd repos/royalvnc
   git apply ../../ci/patches/royalvnc-configurable-quality.patch
   cd ../..
   ```

### Moonlight Dependencies (Optional)

Moonlight streaming requires [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and [Opus](https://opus-codec.org/). The `MOONLIGHT_ENABLED` compilation condition must be set in Xcode build settings to include Moonlight code.

1. Clone moonlight-common-c and apply patches:
   ```bash
   git clone https://github.com/moonlight-stream/moonlight-common-c.git repos/moonlight-common-c
   cp ci/deps/moonlight-common-c/Package.swift repos/moonlight-common-c/
   cd repos/moonlight-common-c
   git apply ../../ci/patches/moonlight-common-c-commoncrypto.patch
   git apply ../../ci/patches/moonlight-common-c-fec-fix.patch
   git apply ../../ci/patches/moonlight-common-c-audio-fec-fix.patch
   cd ../..
   ```

2. Clone Opus and apply the SPM wrapper patch:
   ```bash
   git clone https://github.com/xiph/opus.git repos/opus
   cp ci/deps/opus/Package.swift repos/opus/
   cp -r ci/deps/opus/include repos/opus/spm-include
   cp -r ci/deps/opus/spm-config repos/opus/
   cd repos/opus
   git apply ../../ci/patches/opus-spm-umbrella.patch
   cd ../..
   ```

3. In Xcode, add the local packages:
   - File -> Add Package Dependencies -> Add Local -> select `repos/moonlight-common-c`
   - File -> Add Package Dependencies -> Add Local -> select `repos/opus`

4. Add `MOONLIGHT_ENABLED` to your target's Swift Active Compilation Conditions in Build Settings.

### Building

Open `VisionVNC.xcodeproj` in Xcode, then add the local packages as described above. Build and run on Apple Vision Pro or the visionOS Simulator.

The project is **arm64-only** (`ARCHS = arm64` at the project level) — Apple deprecated x86_64 with macOS Tahoe. When building for the simulator from the command line, use a concrete destination (e.g. `-destination 'platform=visionOS Simulator,name=Apple Vision Pro'`) rather than a generic one.

### Building the Audio Sender (macOS)

The **VisionVNCAudioSender** scheme builds the macOS menu bar app that streams system audio to VisionVNC. It has no external dependencies, so it builds even without the `repos/` setup above. Select the `VisionVNCAudioSender` scheme in Xcode and run, or from the command line:

```bash
xcodebuild -project VisionVNC.xcodeproj -scheme VisionVNCAudioSender -configuration Release build
# Built product:
# ~/Library/Developer/Xcode/DerivedData/VisionVNC-*/Build/Products/Release/VisionVNCAudioSender.app
```

(Add `-derivedDataPath build/dd` to get the app at `build/dd/Build/Products/Release/VisionVNCAudioSender.app` instead.)

Requires macOS 14.2+. On first start of streaming, grant the **System Audio Recording** permission prompt (System Settings → Privacy & Security → Screen & System Audio Recording).

**Usage:**
1. Launch VisionVNCAudioSender on the Mac (speaker icon in the menu bar) and enable **Stream system audio**
2. In VisionVNC on the Vision Pro, add an **Audio** connection pointing at your Mac's IP, port 4855
3. Spatialized Stereo will be off by default, since the Mac Virtual Display's audio stream is always forced into Spatialized Stereo, so if you ever need to stream 5.1/7.1 surround just use Mac VD audio streaming instead.

## Architecture

The app uses a multi-window SwiftUI architecture with two independent protocol paths sharing a common connection list and persistence layer:

```
VisionVNCApp
├── VNC Path
│   ├── VNCConnectionManager      — RoyalVNCKit bridge, @Observable
│   ├── RemoteDesktopView         — Framebuffer display + gesture input
│   └── KeyboardInputView         — Soft keyboard window
│
├── Moonlight Path (#if MOONLIGHT_ENABLED)
│   ├── MoonlightConnectionManager — Session orchestrator, state machine
│   ├── NvHTTPClient              — GameStream HTTP/HTTPS API (NWConnection)
│   ├── NvPairingManager          — PIN-based challenge-response pairing
│   ├── CryptoManager             — X.509/PKCS#12/AES via CommonCrypto
│   ├── MoonlightVideoRenderer    — H.264/HEVC/AV1 via AVSampleBufferDisplayLayer + HDR
│   ├── MoonlightAudioRenderer    — Opus multistream via AVAudioEngine
│   ├── MoonlightGamepadManager   — GameController framework bridge
│   ├── MoonlightStreamBridge     — C callback marshalling to Swift
│   ├── MoonlightStreamView       — Stream display + gesture/mouse input
│   └── MoonlightKeyboardView     — Soft keyboard window
│
├── Audio Path
│   ├── AudioStreamManager        — Stream state, @Observable
│   ├── AudioStreamReceiver       — NWConnection → AVAudioEngine playback
│   └── AudioStreamView           — Stream status window
│
└── Shared
    ├── SavedConnection           — SwiftData model (VNC + Moonlight settings)
    ├── ConnectionListView        — Unified server list, routes by type
    └── ConnectionFormView        — Per-connection settings form

VisionVNCAudioSender (macOS menu bar app)
├── SystemAudioTap                — Core Audio process tap + aggregate device
├── AudioStreamServer             — TCP server, Float32 PCM frames
└── AudioSenderApp                — MenuBarExtra UI

Shared/AudioStreamProtocol.swift  — wire format, compiled into both targets
```

### How Moonlight Streaming Works

This app integrates the **moonlight-common-c** protocol library — the same C core used by [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt), [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios), and [Moonlight Android](https://github.com/moonlight-stream/moonlight-android). Rather than porting one of the full Moonlight client apps to visionOS (which would require rewriting their entire UI layer), VisionVNC embeds only the protocol library and provides native visionOS implementations of:

- **Video decoding** — `AVSampleBufferDisplayLayer` for hardware H.264/HEVC/AV1 decoding with native HDR10 support. Compressed video frames are enqueued directly to the display layer as `CMSampleBuffer`s — the layer handles decoding, HDR tone mapping, and rendering. AV1 bitstream parsing uses a custom OBU parser for sequence header extraction.
- **Audio decoding** — `opus_multistream_decode()` feeding `AVAudioEngine` with `AVAudioPlayerNode`
- **Crypto** — CommonCrypto and Security.framework replace OpenSSL for all pairing, TLS, and stream encryption operations
- **Networking** — `NWConnection` (Network.framework) replaces URLSession for HTTP, enabling custom TLS cert verification and client certificate mutual authentication with Sunshine's self-signed certs
- **Input** — Native `GameController` framework for gamepads, `UIKeyboardHIDUsage` capture for hardware keyboards, mapped to Windows VK codes

The moonlight-common-c library handles RTSP session negotiation, RTP stream demuxing, FEC error correction, and the control protocol. It communicates with Swift through C function pointer callbacks (video frames, audio samples, connection events) that are marshalled to Swift via a bridge layer with global renderer references.

### Patches Applied to moonlight-common-c

The dependencies require several patches for visionOS compatibility (applied automatically in CI, see `ci/patches/`):

| Patch | Purpose |
|-------|---------|
| `moonlight-common-c-commoncrypto.patch` | Replaces OpenSSL with CommonCrypto/Security.framework for AES-GCM encryption, SHA/HMAC operations, and random number generation. Avoids shipping a large OpenSSL binary on Apple platforms. |
| `moonlight-common-c-fec-fix.patch` | Fixes a crash in audio FEC (Forward Error Correction) recovery when packets arrive out of order |
| `moonlight-common-c-audio-fec-fix.patch` | Fixes compatibility with newer Sunshine server versions that changed audio FEC parameters |
| `royalvnc-configurable-quality.patch` | Adds configurable JPEG quality and compression levels to RoyalVNCKit (hardcoded at level 6), plus `pauseFramebufferUpdates()` API for trackpad-only mode |

Opus is wrapped as a local SPM package with a custom `module.modulemap` that exposes the multistream decoder API (`opus_multistream_decoder_create`, `opus_multistream_decode`) which is not included in Opus's default public headers.

## Contributing

Contributions are welcome! Please feel free to submit a pull request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## Third-Party Software

This project uses the following open-source libraries:

- [RoyalVNCKit](https://github.com/royalapplications/royalvnc) by Royal Apps — MIT License
- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) by Moonlight Game Streaming Project — GPLv3 License
- [Opus](https://opus-codec.org/) by Xiph.Org Foundation — BSD 3-Clause License
- [ENet](http://enet.bespin.org/) (bundled with moonlight-common-c) — MIT License

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full license texts.

## License

This project is licensed under the **MIT License** — see [LICENSE.txt](LICENSE.txt) for details.

**Moonlight support** is an optional build-time feature controlled by the `MOONLIGHT_ENABLED` compilation condition. When Moonlight is enabled, the resulting binary links against [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3) and [Opus](https://opus-codec.org/) (BSD 3-Clause), and the combined work falls under the **GPLv3**. When Moonlight is disabled (the default for the open-source build), no GPLv3 code is compiled or linked, and the application remains purely MIT-licensed.
