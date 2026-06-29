import SwiftUI
import AppKit
import os

/// Slim quick-controls popover for the menu bar — the everyday audio toggles
/// and live status. Everything else (token, broadcast/OBS, SSH keys,
/// keyboard control) lives in the companion window.
struct CompanionMenuView: View {
    @Bindable var controller: AudioStreamerController
    @Bindable var broadcastServer: BroadcastServerManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VisionVNC Companion")
                .font(.headline)

            Toggle("Stream system audio", isOn: $controller.isRunning)
                .toggleStyle(.switch)

            Toggle("Mute Mac output while streaming", isOn: $controller.muteWhileStreaming)
                .toggleStyle(.checkbox)
                .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the VisionVNC app.")

            Toggle("Show track in menu bar", isOn: $controller.showTrackInMenuBar)
                .toggleStyle(.checkbox)
                .help("Shows the current Music.app track as \"Artist – Title\" in the menu bar while streaming.")

            Divider()

            Group {
                Text(controller.statusText)
                if controller.isRunning {
                    Text("Port \(String(controller.port)) · \(controller.formatText)")
                }
                if let nowPlaying = controller.nowPlaying, nowPlaying.hasTrack {
                    Text("♪ \(nowPlaying.title ?? "") — \(nowPlaying.artist ?? "")")
                        .lineLimit(1)
                }
                if let error = controller.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            Button("Open Companion Window…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .help("Access token, broadcast server (OBS), SSH keys, and keyboard control.")

            Button("Quit") {
                controller.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
