import ReplayKit
import CoreMedia

/// Broadcast upload extension: receives the composited Vision Pro view
/// ("Mirror My View" / View Sharing) plus optional mic audio from ReplayKit
/// and publishes it over RTSP via the shared BroadcastCore pipeline.
///
/// Runs in its own process, so the stream keeps going while VisionVNC is
/// backgrounded — server settings come from the app-group defaults/keychain
/// written by the app's Broadcast tab. Started from the system View Sharing
/// menu or the picker in the Broadcast tab.
nonisolated final class SampleHandler: RPBroadcastSampleHandler {

    private let videoEncoder = BroadcastVideoEncoder(
        bitrate: (BroadcastShared.defaults.object(forKey: BroadcastShared.Keys.bitrate) as? Int ?? 10) * 1_000_000)
    private let audioEncoder = BroadcastAudioEncoder(channels: 1)
    private nonisolated(unsafe) var publisher: RTSPPublisher?
    private nonisolated(unsafe) var publisherStarted = false
    private nonisolated(unsafe) var stopped = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let config = BroadcastShared.serverConfig(viewStream: true,
                                                        password: BroadcastShared.getPassword()) else {
            finishBroadcastWithError(NSError(
                domain: "VisionVNCBroadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Set the server address in VisionVNC's Broadcast tab first."]))
            return
        }

        videoEncoder.onParameterSets = { [weak self] sps, pps in
            guard let self, !self.publisherStarted else { return }
            self.publisherStarted = true
            self.startPublisher(config: config, sps: sps, pps: pps)
        }
        videoEncoder.onEncodedFrame = { [weak self] nalUnits, pts, _ in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(pts)
            guard seconds.isFinite else { return }
            self.publisher?.sendVideo(nalUnits: nalUnits,
                                      timestamp90k: UInt32(truncatingIfNeeded: Int64((seconds * 90_000).rounded())))
        }
        videoEncoder.onError = { [weak self] message in
            self?.failBroadcast(message)
        }
        audioEncoder.onEncodedFrame = { [weak self] frame, timestamp in
            self?.publisher?.sendAudio(frame: frame, timestamp48k: timestamp)
        }
        audioEncoder.onError = { message in
            // Non-fatal: continue video-only.
            broadcastLog("⚠️ \(message) — view broadcast continuing video-only")
        }
        broadcastLog("▶️ View broadcast starting: \(config.host):\(config.port)/\(config.path)")
    }

    private func startPublisher(config: BroadcastShared.ServerConfig, sps: Data, pps: Data) {
        let sdp = SDPBuilder.build(sessionName: "VisionVNC View", sps: sps, pps: pps, audioChannels: 1)
        let publisher = RTSPPublisher(host: config.host, port: config.port, path: config.path,
                                      username: config.username, password: config.password, sdp: sdp,
                                      pinnedCertSHA256: config.pinnedCertSHA256)
        publisher.onEvent = { [weak self] event in
            switch event {
            case .ready:
                broadcastLog("✅ View broadcast live")
            case .failed(let message):
                self?.failBroadcast(message)
            }
        }
        self.publisher = publisher
        publisher.start()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard !stopped else { return }
        switch sampleBufferType {
        case .video:
            videoEncoder.encode(sampleBuffer)
        case .audioMic:
            // Only flows when the user enables the mic in the View Sharing
            // UI; the SDP always announces the track, silence otherwise.
            audioEncoder.encode(sampleBuffer: sampleBuffer)
        case .audioApp:
            break    // app audio already plays on the receiving side's call
        @unknown default:
            break
        }
    }

    override func broadcastPaused() {
        broadcastLog("⏸️ View broadcast paused")
    }

    override func broadcastResumed() {
        broadcastLog("▶️ View broadcast resumed")
    }

    override func broadcastFinished() {
        teardown()
        broadcastLog("⏹️ View broadcast finished")
    }

    private func failBroadcast(_ message: String) {
        guard !stopped else { return }
        teardown()
        broadcastLog("❌ View broadcast error: \(message)")
        finishBroadcastWithError(NSError(
            domain: "VisionVNCBroadcast", code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func teardown() {
        stopped = true
        publisher?.stop()
        publisher = nil
        videoEncoder.invalidate()
    }
}
