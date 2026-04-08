import Foundation
@preconcurrency import RoyalVNCKit
import QuartzCore
import UIKit

/// Connection state for the app UI
enum AppConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected(error: String?)

    var isActive: Bool {
        switch self {
        case .connecting, .connected, .disconnecting: return true
        default: return false
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Not Connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .disconnected(let error):
            return error != nil ? "Disconnected: \(error!)" : "Disconnected"
        }
    }
}

/// Central orchestrator for VNC connections.
/// Wraps VNCConnection, implements VNCConnectionDelegate, and exposes
/// @Observable state for SwiftUI consumption.
@Observable
final class VNCConnectionManager: NSObject, VNCConnectionDelegate {

    // MARK: - Observable State

    var connectionState: AppConnectionState = .idle
    var connectionTitle: String = ""
    var framebufferImage: CGImage?
    var framebufferSize: CGSize = .zero

    // Credential prompt state
    var isCredentialPromptPresented: Bool = false
    var credentialAuthType: VNCAuthenticationType = .vnc

    // Touch mode & virtual cursor
    var touchMode: TouchMode = .absolute
    var virtualCursorX: UInt16 = 0
    var virtualCursorY: UInt16 = 0

    // Trackpad-only mode (transparent overlay, no video)
    var isTrackpadOnly: Bool = false

    // MARK: - Private State

    private var connection: VNCConnection?
    private var framebuffer: VNCFramebuffer?
    private var storedUsername: String?
    private var storedPassword: String?
    private var credentialCompletion: (((VNCCredential?) -> Void))?

    // Throttle framebuffer rendering via CADisplayLink
    private var pendingImageUpdate: Bool = false
    private var displayLink: CADisplayLink?
    private var virtualCursorInitialized = false

    // MARK: - Connection Lifecycle

    func connect(hostname: String, port: UInt16, username: String? = nil, password: String? = nil, colorDepth: VNCConnection.Settings.ColorDepth = .depth24Bit, touchMode: TouchMode = .absolute, trackpadOnly: Bool = false, title: String? = nil) {
        disconnect()

        self.touchMode = touchMode
        self.isTrackpadOnly = trackpadOnly
        self.virtualCursorInitialized = false

        connectionTitle = title ?? "\(hostname):\(port)"
        storedUsername = username
        storedPassword = password

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: hostname,
            port: port,
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: colorDepth,
            frameEncodings: .default
        )

        let conn = VNCConnection(settings: settings)
        conn.delegate = self
        self.connection = conn
        self.connectionState = .connecting

        conn.connect()

        // Skip display link in trackpad-only mode — no video rendering needed
        if !trackpadOnly {
            startDisplayLink()
        }
    }

    func disconnect() {
        connection?.disconnect()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        stopDisplayLink()

        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 90, preferred: 60
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        guard pendingImageUpdate, let fb = framebuffer else { return }
        pendingImageUpdate = false
        framebufferImage = fb.cgImage
    }

    // MARK: - VNCConnectionDelegate

    nonisolated func connection(_ connection: VNCConnection,
                                stateDidChange connectionState: VNCConnection.ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch connectionState.status {
            case .connecting:
                self.connectionState = .connecting
            case .connected:
                self.connectionState = .connected
            case .disconnecting:
                self.connectionState = .disconnecting
            case .disconnected:
                let errorMsg = connectionState.error?.localizedDescription
                self.connectionState = .disconnected(error: errorMsg)
                self.stopDisplayLink()
                self.connection = nil
                self.framebuffer = nil
                self.framebufferImage = nil
                self.isTrackpadOnly = false
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            // Auto-submit stored credentials if available
            if let password = self.storedPassword, !password.isEmpty {
                self.storedPassword = nil
                if authenticationType.requiresUsername, let username = self.storedUsername, !username.isEmpty {
                    self.storedUsername = nil
                    completion(VNCUsernamePasswordCredential(username: username, password: password))
                    return
                } else if !authenticationType.requiresUsername {
                    completion(VNCPasswordCredential(password: password))
                    return
                }
                // If username required but not provided, fall through to prompt
            }

            // Present credential prompt
            self.credentialCompletion = completion
            self.credentialAuthType = authenticationType
            self.isCredentialPromptPresented = true
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.framebuffer = framebuffer
            self.framebufferSize = size
            if !self.isTrackpadOnly {
                self.framebufferImage = framebuffer.cgImage
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.framebuffer = framebuffer
            self.framebufferSize = size
            if !self.isTrackpadOnly {
                self.framebufferImage = framebuffer.cgImage
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16,
                                width: UInt16, height: UInt16) {
        Task { @MainActor [weak self] in
            self?.pendingImageUpdate = true
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateCursor cursor: VNCCursor) {
        // visionOS has no custom cursor; skip for now
    }

    // MARK: - Credential Submission

    func submitCredential(username: String?, password: String) {
        let credential: VNCCredential
        if let username, credentialAuthType.requiresUsername {
            credential = VNCUsernamePasswordCredential(username: username, password: password)
        } else {
            credential = VNCPasswordCredential(password: password)
        }
        credentialCompletion?(credential)
        credentialCompletion = nil
        isCredentialPromptPresented = false
    }

    func cancelCredential() {
        credentialCompletion?(nil)
        credentialCompletion = nil
        isCredentialPromptPresented = false
    }

    // MARK: - Input Forwarding

    func sendMouseMove(x: UInt16, y: UInt16) {
        connection?.mouseMove(x: x, y: y)
    }

    func sendMouseDown(button: VNCMouseButton, x: UInt16, y: UInt16) {
        connection?.mouseButtonDown(button, x: x, y: y)
    }

    func sendMouseUp(button: VNCMouseButton, x: UInt16, y: UInt16) {
        connection?.mouseButtonUp(button, x: x, y: y)
    }

    func sendScroll(wheel: VNCMouseWheel, x: UInt16, y: UInt16, steps: UInt32 = 3) {
        connection?.mouseWheel(wheel, x: x, y: y, steps: steps)
    }

    func sendKeyDown(_ key: VNCKeyCode) {
        connection?.keyDown(key)
    }

    func sendKeyUp(_ key: VNCKeyCode) {
        connection?.keyUp(key)
    }

    // MARK: - Virtual Cursor (Relative/Touchpad Mode)

    /// Lazily initializes the virtual cursor to the center of the framebuffer.
    private func initializeVirtualCursorIfNeeded() {
        guard !virtualCursorInitialized, framebufferSize.width > 0 else { return }
        virtualCursorX = UInt16(framebufferSize.width / 2)
        virtualCursorY = UInt16(framebufferSize.height / 2)
        virtualCursorInitialized = true
    }

    /// Move the virtual cursor by framebuffer-space deltas, clamped to bounds.
    func moveVirtualCursor(dx: CGFloat, dy: CGFloat) {
        initializeVirtualCursorIfNeeded()

        let newX = CGFloat(virtualCursorX) + dx
        let newY = CGFloat(virtualCursorY) + dy

        virtualCursorX = UInt16(clamping: Int(max(0, min(newX, framebufferSize.width - 1))))
        virtualCursorY = UInt16(clamping: Int(max(0, min(newY, framebufferSize.height - 1))))

        sendMouseMove(x: virtualCursorX, y: virtualCursorY)
    }

    /// Send a click at the current virtual cursor position.
    func clickAtVirtualCursor(button: VNCMouseButton) {
        initializeVirtualCursorIfNeeded()
        sendMouseDown(button: button, x: virtualCursorX, y: virtualCursorY)
        sendMouseUp(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    /// Send scroll at the current virtual cursor position.
    func scrollAtVirtualCursor(wheel: VNCMouseWheel, steps: UInt32 = 3) {
        initializeVirtualCursorIfNeeded()
        sendScroll(wheel: wheel, x: virtualCursorX, y: virtualCursorY, steps: steps)
    }
}
