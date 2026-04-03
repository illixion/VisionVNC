import SwiftUI
@preconcurrency import MoonlightCommonC

/// SwiftUI view that displays the Moonlight video stream and handles input.
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingControls = false
    @State private var showStats = false

    // Track previous drag translation to compute incremental deltas
    @State private var previousDragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = manager.streamFrameImage {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                    .gesture(mouseDragGesture)
                    .gesture(scrollGesture)
                    .onTapGesture(count: 2) {
                        // Two-finger tap = right click (double tap as proxy on visionOS)
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_RIGHT)
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
                    }
                    .onTapGesture {
                        // Single tap = left click
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                    }

                // Invisible hardware keyboard capture overlay
                MoonlightHardwareKeyboardView()
                    .frame(width: 0, height: 0)
                    .opacity(0)
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
                controlsOverlay
            }

            // Statistics overlay
            if showStats {
                StreamStatsOverlay()
                    .environment(manager)
            }
        }
        .persistentSystemOverlays(.hidden)
        .onDisappear {
            manager.stopStreaming()
            dismissWindow(id: "moonlight-keyboard")
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            controlsBar
        }
    }

    // MARK: - Mouse Drag Gesture

    /// Sends incremental mouse move deltas (not cumulative translation).
    private var mouseDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let dx = value.translation.width - previousDragTranslation.width
                let dy = value.translation.height - previousDragTranslation.height
                previousDragTranslation = value.translation

                LiSendMouseMoveEvent(Int16(dx), Int16(dy))
            }
            .onEnded { _ in
                previousDragTranslation = .zero
            }
    }

    // MARK: - Scroll Gesture

    /// Two-finger vertical drag sends scroll events via a MagnifyGesture proxy.
    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Map magnification to scroll: >1 = scroll up, <1 = scroll down
                let delta = value.magnification - 1.0
                let scrollAmount = Int16(delta * 120)
                if scrollAmount != 0 {
                    LiSendHighResScrollEvent(scrollAmount)
                }
            }
    }

    // MARK: - Controls Bar (Ornament)

    private var controlsBar: some View {
        HStack(spacing: 16) {
            Button {
                openWindow(id: "moonlight-keyboard")
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }

            Button {
                showStats.toggle()
            } label: {
                Label("Stats", systemImage: "chart.bar")
            }
            .tint(showStats ? .accentColor : nil)

            Button(role: .destructive) {
                manager.stopStreaming()
                dismissWindow(id: "moonlight-keyboard")
                dismiss()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }

    // MARK: - Controls Overlay (legacy, kept for double-tap toggle)

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    manager.stopStreaming()
                    dismissWindow(id: "moonlight-keyboard")
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
