import SwiftUI
import SwiftData

struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager

    var savedConnection: SavedConnection?

    // Common
    @State private var connectionType: ConnectionType = .vnc
    @State private var hostname: String = ""
    @State private var port: String = "5900"
    @State private var label: String = ""

    // VNC
    @State private var quality: ConnectionQuality = .high
    @State private var autoLogin: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var vncTouchMode: TouchMode = .absolute

    #if MOONLIGHT_ENABLED
    // Moonlight — Video
    @State private var moonlightResolution: MoonlightResolution = .r1080p
    @State private var moonlightFPS: Int = 60
    @State private var moonlightBitrate: Double = 20000
    @State private var moonlightVideoCodec: VideoCodecPreference = .auto
    @State private var moonlightEnableHDR: Bool = false
    @State private var moonlightUseFramePacing: Bool = false

    // Moonlight — Audio
    @State private var moonlightAudioConfig: AudioConfiguration = .stereo
    @State private var moonlightPlayAudioOnPC: Bool = false

    // Moonlight — Input
    @State private var moonlightTouchMode: TouchMode = .relative
    @State private var moonlightMultiController: Bool = true
    @State private var moonlightSwapABXY: Bool = false

    // Moonlight — Server
    @State private var moonlightOptimizeGameSettings: Bool = true

    // Moonlight — Debug
    @State private var moonlightShowStatsOverlay: Bool = false
    #endif

    private var hasCredentials: Bool {
        !password.isEmpty
    }

    private var isEditing: Bool {
        savedConnection != nil
    }

    var body: some View {
        Form {
            connectionTypeSection
            serverSection

            switch connectionType {
            case .vnc:
                vncSections
            #if MOONLIGHT_ENABLED
            case .moonlight:
                moonlightSections
            #endif
            }

            labelSection
        }
        .navigationTitle(isEditing ? "Edit Connection" : "New Connection")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveConnection()
                }
                .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: loadFromSavedConnection)
        .onChange(of: connectionType) { _, newType in
            port = String(newType.defaultPort)
        }
    }

    // MARK: - Shared Sections

    private var connectionTypeSection: some View {
        Section {
            Picker("Type", selection: $connectionType) {
                ForEach(ConnectionType.allCases, id: \.self) { type in
                    Label(type.label, systemImage: type.systemImage).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isEditing) // Can't change type after creation
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Hostname or IP Address", text: $hostname)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            TextField("Port", text: $port)
                .keyboardType(.numberPad)
        }
    }

    private var labelSection: some View {
        Section("Label") {
            TextField("Display Name (optional)", text: $label)
        }
    }

    // MARK: - VNC Sections

    @ViewBuilder
    private var vncSections: some View {
        Section("Authentication") {
            Toggle("Auto Login", isOn: $autoLogin)

            if autoLogin {
                TextField("Username (optional)", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                if isEditing && hasCredentials {
                    Button("Clear Saved Credentials", role: .destructive) {
                        username = ""
                        password = ""
                    }
                }
            }
        }

        Section("Quality") {
            Picker("Quality", selection: $quality) {
                ForEach(ConnectionQuality.allCases, id: \.self) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)

            Text(quality.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Input") {
            Picker("Touch Mode", selection: $vncTouchMode) {
                ForEach(TouchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Text(vncTouchMode == .relative
                ? "Drag to move the cursor. Tap to click at the cursor position. Double-tap for right-click."
                : "Tap and drag directly on the remote screen. Double-tap for right-click.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #if MOONLIGHT_ENABLED
    // MARK: - Moonlight Sections

    @ViewBuilder
    private var moonlightSections: some View {
        moonlightVideoSection
        moonlightAudioSection
        moonlightInputSection
        moonlightServerSection
        moonlightDebugSection
    }

    private var moonlightVideoSection: some View {
        Section("Video") {
            Picker("Resolution", selection: $moonlightResolution) {
                ForEach(MoonlightResolution.allCases, id: \.self) { res in
                    Text(res.label).tag(res)
                }
            }
            .onChange(of: moonlightResolution) { _, _ in
                recalculateSuggestedBitrate()
            }

            Picker("Frame Rate", selection: $moonlightFPS) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
                Text("120 FPS").tag(120)
            }
            .onChange(of: moonlightFPS) { _, _ in
                recalculateSuggestedBitrate()
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Text(bitrateLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $moonlightBitrate, in: 500...150_000, step: 500)
            }

            Picker("Video Codec", selection: $moonlightVideoCodec) {
                ForEach(VideoCodecPreference.allCases, id: \.self) { codec in
                    Text(codec.label).tag(codec)
                }
            }

            Toggle("HDR", isOn: $moonlightEnableHDR)

            Picker("Frame Delivery", selection: $moonlightUseFramePacing) {
                Text("Lowest Latency").tag(false)
                Text("Smoothest Video").tag(true)
            }
        }
    }

    private var moonlightAudioSection: some View {
        Section("Audio") {
            Picker("Audio Configuration", selection: $moonlightAudioConfig) {
                ForEach(AudioConfiguration.allCases, id: \.self) { config in
                    Text(config.label).tag(config)
                }
            }

            Toggle("Play Audio on Host PC", isOn: $moonlightPlayAudioOnPC)
        }
    }

    private var moonlightInputSection: some View {
        Section("Input") {
            Picker("Touch Mode", selection: $moonlightTouchMode) {
                ForEach(TouchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Toggle("Multi-Controller Support", isOn: $moonlightMultiController)
            Toggle("Swap A/B and X/Y Buttons", isOn: $moonlightSwapABXY)
        }
    }

    private var moonlightServerSection: some View {
        Section("Server") {
            Toggle("Optimize Game Settings", isOn: $moonlightOptimizeGameSettings)
        }
    }

    private var moonlightDebugSection: some View {
        Section("Debug") {
            Toggle("Statistics Overlay", isOn: $moonlightShowStatsOverlay)
        }
    }

    // MARK: - Helpers

    private var bitrateLabel: String {

        let mbps = moonlightBitrate / 1000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f Kbps", moonlightBitrate)
        }
    }

    private func recalculateSuggestedBitrate() {
        let (w, h) = moonlightResolution.dimensions
        moonlightBitrate = Double(SavedConnection.suggestedBitrate(width: w, height: h, fps: moonlightFPS))
    }
    #endif

    // MARK: - Load / Save

    private func loadFromSavedConnection() {
        guard let saved = savedConnection else { return }

        connectionType = saved.connectionType
        hostname = saved.hostname
        port = String(saved.port)
        label = saved.label

        // VNC fields
        quality = saved.quality
        autoLogin = saved.autoLogin
        username = saved.savedUsername
        password = saved.savedPassword
        vncTouchMode = saved.vncTouchMode

        #if MOONLIGHT_ENABLED
        // Moonlight fields
        moonlightResolution = MoonlightResolution.from(
            width: saved.moonlightResolutionWidth,
            height: saved.moonlightResolutionHeight
        )
        moonlightFPS = saved.moonlightFPS
        moonlightBitrate = Double(saved.moonlightBitrate)
        moonlightVideoCodec = saved.moonlightVideoCodec
        moonlightEnableHDR = saved.moonlightEnableHDR
        moonlightUseFramePacing = saved.moonlightUseFramePacing
        moonlightAudioConfig = saved.moonlightAudioConfig
        moonlightPlayAudioOnPC = saved.moonlightPlayAudioOnPC
        moonlightTouchMode = saved.moonlightTouchMode
        moonlightMultiController = saved.moonlightMultiController
        moonlightSwapABXY = saved.moonlightSwapABXY
        moonlightOptimizeGameSettings = saved.moonlightOptimizeGameSettings
        moonlightShowStatsOverlay = saved.moonlightShowStatsOverlay
        #endif
    }

    private func saveConnection() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let portNum = Int(port) ?? connectionType.defaultPort

        if let saved = savedConnection {
            saved.hostname = trimmedHost
            saved.port = portNum
            saved.label = label.isEmpty ? "\(trimmedHost):\(portNum)" : label
            saveTypeSpecificFields(to: saved)
        } else {
            let newConnection = SavedConnection(
                hostname: trimmedHost,
                port: portNum,
                label: label,
                connectionType: connectionType
            )
            saveTypeSpecificFields(to: newConnection)
            modelContext.insert(newConnection)
        }

        dismiss()
    }

    private func saveTypeSpecificFields(to connection: SavedConnection) {
        switch connectionType {
        case .vnc:
            connection.quality = quality
            connection.autoLogin = autoLogin
            connection.savedUsername = autoLogin ? username : ""
            connection.savedPassword = autoLogin ? password : ""
            connection.vncTouchMode = vncTouchMode

        #if MOONLIGHT_ENABLED
        case .moonlight:
            let (w, h) = moonlightResolution.dimensions
            connection.moonlightResolutionWidth = w
            connection.moonlightResolutionHeight = h
            connection.moonlightFPS = moonlightFPS
            connection.moonlightBitrate = Int(moonlightBitrate)
            connection.moonlightVideoCodec = moonlightVideoCodec
            connection.moonlightEnableHDR = moonlightEnableHDR
            connection.moonlightUseFramePacing = moonlightUseFramePacing
            connection.moonlightAudioConfig = moonlightAudioConfig
            connection.moonlightPlayAudioOnPC = moonlightPlayAudioOnPC
            connection.moonlightTouchMode = moonlightTouchMode
            connection.moonlightMultiController = moonlightMultiController
            connection.moonlightSwapABXY = moonlightSwapABXY
            connection.moonlightOptimizeGameSettings = moonlightOptimizeGameSettings
            connection.moonlightShowStatsOverlay = moonlightShowStatsOverlay
        #endif
        }
    }
}

#if MOONLIGHT_ENABLED
// MARK: - Resolution Helper

enum MoonlightResolution: String, CaseIterable {
    case r720p
    case r1080p
    case r1440p
    case r4k

    var label: String {
        switch self {
        case .r720p: "720p"
        case .r1080p: "1080p"
        case .r1440p: "1440p"
        case .r4k: "4K"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .r720p: (1280, 720)
        case .r1080p: (1920, 1080)
        case .r1440p: (2560, 1440)
        case .r4k: (3840, 2160)
        }
    }

    static func from(width: Int, height: Int) -> MoonlightResolution {
        switch (width, height) {
        case (1280, 720): return .r720p
        case (1920, 1080): return .r1080p
        case (2560, 1440): return .r1440p
        case (3840, 2160): return .r4k
        default: return .r1080p
        }
    }
}
#endif
