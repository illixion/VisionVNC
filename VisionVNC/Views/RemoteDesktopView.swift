import SwiftUI
import RoyalVNCKit

struct RemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var isDragging = false
    @State private var previousDragTranslation: CGSize = .zero

    var body: some View {
        Group {
            if connectionManager.isTrackpadOnly {
                // Trackpad-only: no NavigationStack — its glass background blocks transparency
                coreContent
                    .overlay(alignment: .bottom) {
                        toolbar
                            .padding(.bottom, 16)
                    }
            } else {
                NavigationStack {
                    coreContent
                        .navigationTitle(connectionManager.connectionTitle)
                        .overlay(alignment: .bottom) {
                            toolbar
                                .padding(.bottom, 16)
                        }
                }
                .glassBackgroundEffect()
            }
        }
        .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
            CredentialPromptView()
        }
        .onDisappear {
            // When the window is closed (by system close button or programmatically),
            // ensure the VNC connection is torn down and keyboard window is closed.
            dismissWindow(id: "keyboard")
            if connectionManager.connectionState.isActive {
                connectionManager.disconnect()
            }
        }
        .onChange(of: connectionManager.connectionState) { _, newValue in
            if case .disconnected = newValue {
                // Server-initiated disconnect: close windows after a brief delay
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    dismissWindow(id: "keyboard")
                    dismissWindow(id: "remote-desktop")
                }
            }
        }
    }

    // MARK: - Core Content

    @ViewBuilder
    private var coreContent: some View {
        ZStack {
            // Invisible hardware keyboard capture
            HardwareKeyboardView(connectionManager: connectionManager)
                .frame(width: 0, height: 0)
                .opacity(0)

            GeometryReader { geometry in
                ZStack {
                    if connectionManager.isTrackpadOnly {
                        if connectionManager.connectionState == .connected {
                            Color.white.opacity(0.001) // Near-invisible but captures taps
                            cornerBrackets
                        } else {
                            statusView
                        }
                    } else if let cgImage = connectionManager.framebufferImage {
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Virtual cursor indicator for touchpad mode
                        if connectionManager.touchMode == .relative,
                           connectionManager.framebufferSize.width > 0 {
                            cursorOverlay
                        }
                    } else {
                        statusView
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { handleDoubleTap() }
                .gesture(tapGesture)
                .gesture(dragGesture)
                .gesture(scrollGesture)
                .onAppear {
                    viewSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                }
            }
        }
    }

    // MARK: - Status View

    private var statusView: some View {
        VStack(spacing: 20) {
            if case .disconnected(let error) = connectionManager.connectionState {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text(error ?? "Disconnected")
                    .font(.headline)
                Button("Close") {
                    dismissWindow(id: "remote-desktop")
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(connectionManager.connectionState.statusText)
                    .font(.headline)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 20) {
            Button(action: {
                connectionManager.touchMode = connectionManager.touchMode == .absolute
                    ? .relative : .absolute
            }) {
                Label(
                    connectionManager.touchMode == .absolute ? "Direct" : "Touchpad",
                    systemImage: connectionManager.touchMode == .absolute
                        ? "hand.tap" : "rectangle.and.hand.point.up.left"
                )
            }

            Button(action: { openWindow(id: "keyboard") }) {
                Label("Keyboard", systemImage: "keyboard")
            }

            Button(action: sendCtrlAltDel) {
                Label("Ctrl+Alt+Del", systemImage: "power")
            }

            Button(action: {
                connectionManager.disconnect()
                dismissWindow(id: "keyboard")
                dismissWindow(id: "remote-desktop")
            }) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .clipShape(Capsule())
    }

    // MARK: - Gestures

    /// Tap = left click (absolute: at tap location, relative: at virtual cursor)
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if connectionManager.touchMode == .absolute {
                    guard let point = translator?.viewToFramebuffer(value.location) else { return }
                    connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
                    connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
                } else {
                    connectionManager.clickAtVirtualCursor(button: .left)
                }
            }
    }

    /// Drag: absolute = click-and-drag, relative = move cursor (no button held)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if connectionManager.touchMode == .absolute {
                    guard let point = translator?.viewToFramebuffer(value.location) else { return }
                    if !isDragging {
                        isDragging = true
                        connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
                    } else {
                        connectionManager.sendMouseMove(x: point.x, y: point.y)
                    }
                } else {
                    // Relative: compute incremental deltas
                    let dx = value.translation.width - previousDragTranslation.width
                    let dy = value.translation.height - previousDragTranslation.height
                    previousDragTranslation = value.translation

                    if let delta = translator?.viewDeltaToFramebufferDelta(dx: dx, dy: dy) {
                        connectionManager.moveVirtualCursor(dx: delta.dx, dy: delta.dy)
                    }
                }
            }
            .onEnded { value in
                if connectionManager.touchMode == .absolute {
                    if let point = translator?.viewToFramebuffer(value.location) {
                        connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
                    }
                }
                isDragging = false
                previousDragTranslation = .zero
            }
    }

    /// Double-tap = right click
    private func handleDoubleTap() {
        if connectionManager.touchMode == .absolute {
            // Right-click at center of framebuffer as approximation
            let centerX = UInt16(connectionManager.framebufferSize.width / 2)
            let centerY = UInt16(connectionManager.framebufferSize.height / 2)
            connectionManager.sendMouseDown(button: .right, x: centerX, y: centerY)
            connectionManager.sendMouseUp(button: .right, x: centerX, y: centerY)
        } else {
            connectionManager.clickAtVirtualCursor(button: .right)
        }
    }

    /// Pinch = scroll wheel
    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification - 1.0
                guard abs(delta) > 0.01 else { return }

                let wheel: VNCMouseWheel = delta > 0 ? .up : .down
                let steps = UInt32(max(1, abs(delta) * 10))

                if connectionManager.touchMode == .absolute {
                    let centerX = UInt16(connectionManager.framebufferSize.width / 2)
                    let centerY = UInt16(connectionManager.framebufferSize.height / 2)
                    connectionManager.sendScroll(wheel: wheel, x: centerX, y: centerY, steps: steps)
                } else {
                    connectionManager.scrollAtVirtualCursor(wheel: wheel, steps: steps)
                }
            }
    }

    // MARK: - Helpers

    private var translator: GestureTranslator? {
        guard connectionManager.framebufferSize.width > 0 else { return nil }
        return GestureTranslator(
            framebufferSize: connectionManager.framebufferSize,
            viewSize: viewSize,
            trackpadOnly: connectionManager.isTrackpadOnly
        )
    }

    private var cursorOverlay: some View {
        let point = translator?.framebufferToView(
            x: connectionManager.virtualCursorX,
            y: connectionManager.virtualCursorY
        ) ?? .zero

        return Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(point)
            .allowsHitTesting(false)
    }

    /// L-shaped corner brackets indicating the trackpad boundary
    private var cornerBrackets: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let arm: CGFloat = 40

            Path { path in
                // Top-left
                path.move(to: CGPoint(x: 0, y: arm))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: arm, y: 0))

                // Top-right
                path.move(to: CGPoint(x: w - arm, y: 0))
                path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: arm))

                // Bottom-left
                path.move(to: CGPoint(x: 0, y: h - arm))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: arm, y: h))

                // Bottom-right
                path.move(to: CGPoint(x: w - arm, y: h))
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w, y: h - arm))
            }
            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private func sendCtrlAltDel() {
        connectionManager.sendKeyDown(.control)
        connectionManager.sendKeyDown(.option)
        connectionManager.sendKeyDown(.forwardDelete)
        connectionManager.sendKeyUp(.forwardDelete)
        connectionManager.sendKeyUp(.option)
        connectionManager.sendKeyUp(.control)
    }
}
