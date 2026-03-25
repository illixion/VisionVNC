import SwiftUI
import RoyalVNCKit

struct RemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var showKeyboardInput = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            // Invisible hardware keyboard capture
            HardwareKeyboardView(connectionManager: connectionManager)
                .frame(width: 0, height: 0)
                .opacity(0)

            // Framebuffer display
            GeometryReader { geometry in
                ZStack {
                    if let cgImage = connectionManager.framebufferImage {
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        statusView
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(tapGesture)
                .gesture(dragGesture)
                .onAppear {
                    viewSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                }
            }
        }
        .overlay(alignment: .bottom) {
            toolbar
                .padding(.bottom, 16)
        }
        .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
            CredentialPromptView()
        }
        .sheet(isPresented: $showKeyboardInput) {
            KeyboardInputView()
        }
        .onDisappear {
            // When the window is closed (by system close button or programmatically),
            // ensure the VNC connection is torn down.
            if connectionManager.connectionState.isActive {
                connectionManager.disconnect()
            }
        }
        .onChange(of: connectionManager.connectionState) { _, newValue in
            if case .disconnected = newValue {
                // Server-initiated disconnect: close the window after a brief delay
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    dismissWindow(id: "remote-desktop")
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
            Button(action: { showKeyboardInput = true }) {
                Label("Keyboard", systemImage: "keyboard")
            }

            Button(action: sendCtrlAltDel) {
                Label("Ctrl+Alt+Del", systemImage: "power")
            }

            Button(action: {
                connectionManager.disconnect()
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

    /// Tap = left click
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = translator?.viewToFramebuffer(value.location) else { return }
                connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
                connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
            }
    }

    /// Drag = mouse move while holding left button
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let point = translator?.viewToFramebuffer(value.location) else { return }
                if !isDragging {
                    isDragging = true
                    connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
                } else {
                    connectionManager.sendMouseMove(x: point.x, y: point.y)
                }
            }
            .onEnded { value in
                guard let point = translator?.viewToFramebuffer(value.location) else {
                    isDragging = false
                    return
                }
                connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
                isDragging = false
            }
    }

    // MARK: - Helpers

    private var translator: GestureTranslator? {
        guard connectionManager.framebufferSize.width > 0 else { return nil }
        return GestureTranslator(
            framebufferSize: connectionManager.framebufferSize,
            viewSize: viewSize
        )
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
