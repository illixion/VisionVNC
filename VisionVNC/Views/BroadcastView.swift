import SwiftUI
import AVFoundation
import ReplayKit

/// Broadcast tab: stream a visionOS camera (Persona / Mirror My View) plus
/// the mic to a mediamtx RTSP server, for OBS / video-call capture on the
/// receiving computer. The stream survives tab switches (the manager is
/// app-scoped) but not app backgrounding — visionOS pauses capture when
/// the app loses visibility.
struct BroadcastView: View {
    @Environment(BroadcastManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        NavigationStack {
            Form {
                Section {
                    BroadcastPreview(target: manager.previewTarget)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            if !manager.isActive {
                                Label("Preview starts with the broadcast", systemImage: "video.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section("Source") {
                    Picker("Camera", selection: $manager.selectedCameraID) {
                        ForEach(manager.cameras) { camera in
                            Text(camera.name).tag(Optional(camera.id))
                        }
                    }
                    .disabled(manager.isActive)
                    Toggle("Microphone", isOn: $manager.micEnabled)
                        .disabled(manager.isActive)
                    Picker("Video bitrate", selection: $manager.bitrateMbps) {
                        ForEach([5, 10, 15, 20], id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                    .disabled(manager.isActive)
                }

                Section {
                    HStack {
                        Label("Mirror My View", systemImage: "eye")
                        Spacer()
                        BroadcastPickerButton()
                            .frame(width: 60, height: 44)
                    }
                    TextField("View stream path", text: $manager.viewStreamPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(manager.isActive)
                } header: {
                    Text("View Sharing")
                } footer: {
                    Text("Streams everything you see (runs in the background, separate from the camera broadcast above). Uses the same server with this stream path.")
                }

                Section {
                    TextField("Host", text: $manager.host, prompt: Text("100.x.x.x or hostname"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $manager.port, format: .number.grouping(.never))
                    TextField("Stream path", text: $manager.streamPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Username", text: $manager.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $manager.password)
                    LabeledContent("Encryption") {
                        Label(manager.certFingerprint.isEmpty ? "None — use Tailscale/VPN" : "RTSPS, pinned certificate",
                              systemImage: manager.certFingerprint.isEmpty ? "lock.open" : "lock.fill")
                            .foregroundStyle(manager.certFingerprint.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                            .font(.callout)
                    }
                } header: {
                    Text("Server (mediamtx over RTSP)")
                } footer: {
                    Text("Easiest setup: press \"Set Up Broadcast Server\" in the Mac companion, then AirDrop the pairing link — it fills all of this in, including the encryption certificate.")
                }
                .disabled(manager.isActive)

                Section {
                    Button {
                        if manager.isActive {
                            manager.stop()
                        } else {
                            Task { await manager.start() }
                        }
                    } label: {
                        Label(manager.isActive ? "Stop Broadcast" : "Start Broadcast",
                              systemImage: manager.isActive ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(manager.isActive ? .red : .accentColor)

                    statusRow
                } footer: {
                    Text("Capture pauses if VisionVNC leaves the foreground — keep the app visible while broadcasting.")
                }
            }
            .navigationTitle("Broadcast")
        }
        .task {
            if manager.cameras.isEmpty { manager.refreshCameras() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch manager.state {
        case .idle:
            Label("Idle", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .broadcasting:
            HStack {
                Label("Live", systemImage: "record.circle")
                    .foregroundStyle(.red)
                Spacer()
                Text("\(manager.statsFPS) fps · \(manager.statsKbps.formatted()) kbps" +
                     (manager.audioActive ? " · mic" : ""))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// System View Sharing entry point for the Mirror My View broadcast
/// extension — visionOS renders this as the broadcast start/stop button.
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = BroadcastShared.extensionBundleID
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Live broadcast preview: an `AVSampleBufferDisplayLayer` that
/// `BroadcastPreviewTarget` feeds raw capture frames into (visionOS has no
/// `AVCaptureVideoPreviewLayer`).
private struct BroadcastPreview: UIViewRepresentable {
    let target: BroadcastPreviewTarget

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.displayLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        target.layer = uiView.displayLayer
    }
}
