import SwiftUI
@preconcurrency import MoonlightCommonC

/// SwiftUI view that displays the Moonlight video stream and handles touch input.
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var showingControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = manager.streamFrameImage {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
