# VisionVNC

A native VNC viewer for Apple Vision Pro, built in Swift with SwiftUI.

## Features

- Connect to any VNC server on your local network
- Auto-login with saved credentials (supports VNC password and macOS Screen Sharing username/password auth)
- Hardware and Bluetooth keyboard support with full key mapping
- On-screen soft keyboard with modifier keys, function keys, and arrow keys
- Configurable color quality (16-bit or 24-bit)
- Multi-window interface — remote desktop, keyboard, and server list as separate windows
- Saved connections with SwiftData persistence

## Requirements

- Apple Vision Pro or visionOS Simulator
- visionOS 26.0+
- Xcode 26.0+

## Setup

VisionVNC uses [RoyalVNCKit](https://github.com/royalapps/royalvnc) for the VNC protocol implementation.

1. Clone this repository:
   ```bash
   git clone https://github.com/Illixion/VisionVNC.git
   cd VisionVNC
   ```

2. Clone the RoyalVNCKit dependency:
   ```bash
   mkdir -p repos
   git clone https://github.com/royalapps/royalvnc.git repos/royalvnc
   ```

3. Change the RoyalVNCKit library type to static in `repos/royalvnc/Package.swift`:
   ```swift
   // Change .dynamic to .static
   .library(name: "RoyalVNCKit", type: .static, targets: ["RoyalVNCKit"]),
   ```

4. Open `VisionVNC.xcodeproj` in Xcode, then add the local `repos/royalvnc` package:
   - File → Add Package Dependencies → Add Local → select `repos/royalvnc`

5. Build and run on Apple Vision Pro or the visionOS Simulator.

## Architecture

The app uses a multi-window SwiftUI architecture:

- **Connection List** — Main window for managing saved VNC servers
- **Remote Desktop** — Displays the remote framebuffer with gesture-based mouse input
- **Keyboard** — Separate window with soft keyboard controls for modifier keys, special keys, and text input

`VNCConnectionManager` is the central bridge between RoyalVNCKit and SwiftUI, using `@Observable` for reactive state updates and `CADisplayLink` for throttled framebuffer rendering.

## Contributing

Contributions are welcome! Please feel free to submit a pull request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## Third-Party Software

This project uses [RoyalVNCKit](https://github.com/royalapps/royalvnc) by Royal Apps, licensed under the MIT License. See the in-app Third-Party Notices for full license text.

## License

This project is licensed under the MIT License — see [LICENSE.txt](LICENSE.txt) for details.
