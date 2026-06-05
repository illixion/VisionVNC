import SwiftUI

/// App delegate whose sole job is to surface the Local Network permission
/// prompt as early as possible — before the user tries to connect to a VNC,
/// Moonlight, or audio sender on the LAN. Without the grant, `NWConnection`
/// and the audio receiver's `NWListener` silently fail to reach the host.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        triggerLocalNetworkAccessPrompt()
        return true
    }

    /// Accessing `ProcessInfo.processInfo.hostName` performs a local-network
    /// lookup, which is enough to make the system show the Local Network
    /// permission dialog. The value is discarded — the read is the trigger.
    private func triggerLocalNetworkAccessPrompt() {
        let hostName = ProcessInfo.processInfo.hostName
        AppLog.app.line("Local network access prompt triggered (host: \(hostName))")
    }
}
