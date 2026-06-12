import Foundation

/// Builds the SDP body for the RTSP ANNOUNCE that registers the broadcast
/// with mediamtx: one H.264 video track and (optionally) one Opus audio
/// track, both using the dynamic payload types the packetizers emit.
nonisolated enum SDPBuilder {

    static let videoPayloadType: UInt8 = 96
    static let audioPayloadType: UInt8 = 97
    static let videoControl = "trackID=0"
    static let audioControl = "trackID=1"

    /// `sps`/`pps` are raw NAL units (no start code) from the encoder's
    /// format description. `audioChannels` nil omits the audio track.
    static func build(sessionName: String, sps: Data, pps: Data, audioChannels: Int?) -> String {
        let spsBytes = [UInt8](sps)
        // profile-level-id is the hex of profile_idc/constraint_flags/level_idc
        // (the 3 bytes after the NAL header).
        let profileLevelID = spsBytes.count >= 4
            ? spsBytes[1...3].map { String(format: "%02X", $0) }.joined()
            : "42C01F"
        let spropParameterSets = "\(sps.base64EncodedString()),\(pps.base64EncodedString())"

        var lines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=\(sessionName)",
            "t=0 0",
            "m=video 0 RTP/AVP \(videoPayloadType)",
            "a=rtpmap:\(videoPayloadType) H264/90000",
            "a=fmtp:\(videoPayloadType) packetization-mode=1; sprop-parameter-sets=\(spropParameterSets); profile-level-id=\(profileLevelID)",
            "a=control:\(videoControl)",
        ]
        if let channels = audioChannels {
            lines += [
                "m=audio 0 RTP/AVP \(audioPayloadType)",
                // RFC 7587: the rtpmap channel count is always 2; actual
                // channel layout is signaled via sprop-stereo.
                "a=rtpmap:\(audioPayloadType) opus/48000/2",
                "a=fmtp:\(audioPayloadType) sprop-stereo=\(channels >= 2 ? 1 : 0)",
                "a=control:\(audioControl)",
            ]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
