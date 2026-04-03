import SwiftUI
import AVFoundation
@preconcurrency import MoonlightCommonC

/// SwiftUI view that displays the Moonlight video stream and handles touch input.
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var showingControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = manager.videoRenderer {
                VideoDisplayView(displayLayer: renderer.displayLayer)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let delta = value.translation
                                LiSendMouseMoveEvent(Int16(delta.width), Int16(delta.height))
                            }
                    )
                    .onTapGesture(count: 2) {
                        // Double tap toggles controls overlay
                        showingControls.toggle()
                    }
                    .onTapGesture {
                        // Single tap = left click
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                    }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(manager.statusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            // Controls overlay
            if showingControls {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            manager.stopStreaming()
                            dismiss()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .onDisappear {
            manager.stopStreaming()
        }
    }
}

/// UIViewRepresentable that hosts an AVSampleBufferDisplayLayer.
private struct VideoDisplayView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView()
        view.setDisplayLayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: VideoLayerHostView, context: Context) {}
}

/// UIView subclass that hosts an AVSampleBufferDisplayLayer.
private class VideoLayerHostView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
