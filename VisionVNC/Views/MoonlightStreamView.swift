import SwiftUI
@preconcurrency import MoonlightCommonC

/// SwiftUI view that displays the Moonlight video stream and handles input.
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showStats = false
    @State private var showDisconnectAlert = false

    // Track previous drag translation to compute incremental deltas (relative mode)
    @State private var previousDragTranslation: CGSize = .zero
    // Track whether a drag is actively holding the mouse button (absolute mode)
    @State private var absoluteDragActive = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = manager.streamFrameImage {
                GeometryReader { geometry in
                    Image(decorative: frame, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(mouseDragGesture(in: geometry.size))
                        .gesture(scrollGesture)
                        .onTapGesture(count: 2) {
                            // Double tap = right click
                            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_RIGHT)
                            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
                        }
                        .onTapGesture { location in
                            handleTap(at: location, in: geometry.size)
                        }
                }
                .ignoresSafeArea()

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
        .alert("Disconnect", isPresented: $showDisconnectAlert) {
            Button("Keep Running") {
                manager.stopStreaming()
                dismissWindow(id: "moonlight-keyboard")
                dismiss()
            }
            Button("End Session", role: .destructive) {
                manager.stopStreamingAndQuit()
                dismissWindow(id: "moonlight-keyboard")
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to end the session on the server, or keep it running for later?")
        }
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint, in viewSize: CGSize) {
        if manager.touchMode == .absolute {
            // Map tap location to stream coordinates and send absolute position + click
            let (streamX, streamY) = mapToStreamCoordinates(location, in: viewSize)
            LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
        }
        // Left click (both modes)
        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
    }

    // MARK: - Coordinate Mapping

    /// Maps a view-space point to stream-resolution coordinates, accounting for aspect-ratio letterboxing.
    private func mapToStreamCoordinates(_ point: CGPoint, in viewSize: CGSize) -> (Int16, Int16) {
        let streamW = CGFloat(manager.streamWidth)
        let streamH = CGFloat(manager.streamHeight)
        let streamAspect = streamW / streamH
        let viewAspect = viewSize.width / viewSize.height

        let renderRect: CGRect
        if viewAspect > streamAspect {
            // Letterboxed (pillarboxed) — black bars on left/right
            let renderHeight = viewSize.height
            let renderWidth = renderHeight * streamAspect
            let offsetX = (viewSize.width - renderWidth) / 2
            renderRect = CGRect(x: offsetX, y: 0, width: renderWidth, height: renderHeight)
        } else {
            // Letterboxed — black bars on top/bottom
            let renderWidth = viewSize.width
            let renderHeight = renderWidth / streamAspect
            let offsetY = (viewSize.height - renderHeight) / 2
            renderRect = CGRect(x: 0, y: offsetY, width: renderWidth, height: renderHeight)
        }

        // Clamp point within render rect and normalize to stream coordinates
        let clampedX = min(max(point.x, renderRect.minX), renderRect.maxX)
        let clampedY = min(max(point.y, renderRect.minY), renderRect.maxY)

        let normalizedX = (clampedX - renderRect.minX) / renderRect.width
        let normalizedY = (clampedY - renderRect.minY) / renderRect.height

        let x = Int16(normalizedX * streamW)
        let y = Int16(normalizedY * streamH)
        return (x, y)
    }

    // MARK: - Mouse Drag Gesture

    private func mouseDragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if manager.touchMode == .absolute {
                    let (streamX, streamY) = mapToStreamCoordinates(value.location, in: viewSize)
                    LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
                    // Press button on first drag update for click-and-drag
                    if !absoluteDragActive {
                        absoluteDragActive = true
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                    }
                } else {
                    // Relative: send incremental deltas
                    let dx = value.translation.width - previousDragTranslation.width
                    let dy = value.translation.height - previousDragTranslation.height
                    previousDragTranslation = value.translation
                    LiSendMouseMoveEvent(Int16(dx), Int16(dy))
                }
            }
            .onEnded { value in
                if manager.touchMode == .absolute && absoluteDragActive {
                    // Send final position then release button
                    let (streamX, streamY) = mapToStreamCoordinates(value.location, in: viewSize)
                    LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
                    LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                    absoluteDragActive = false
                }
                previousDragTranslation = .zero
            }
    }

    // MARK: - Scroll Gesture

    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
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
                showDisconnectAlert = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }
}
