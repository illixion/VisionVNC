import Foundation
import CryptoKit

/// Minimal obs-websocket v5 client (the protocol OBS 28+ ships natively;
/// enable under Tools → WebSocket Server Settings) — just enough to
/// provision the two Vision Pro Browser Sources: Hello/Identify handshake
/// with challenge auth, then sequential requests.
final class OBSWebSocketClient {

    enum OBSError: LocalizedError {
        case notRunning
        case authRequired
        case authFailed
        case requestFailed(String, Int)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                "Couldn't reach OBS — is it running with the WebSocket server enabled (Tools → WebSocket Server Settings)?"
            case .authRequired:
                "OBS requires a WebSocket password — copy it from Tools → WebSocket Server Settings into the field here."
            case .authFailed:
                "OBS rejected the WebSocket password."
            case .requestFailed(let type, let code):
                "OBS request \(type) failed (code \(code))."
            }
        }
    }

    private let task: URLSessionWebSocketTask

    init(port: UInt16 = 4455) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    struct BrowserSource {
        let name: String
        let url: String
        /// Initial/enforced visibility. Both sources are full-canvas and a
        /// dead WHEP page draws an opaque "stream not found" error, so only
        /// one should be visible by default.
        let visible: Bool
    }

    /// Creates (or updates, if they exist) browser sources in the current
    /// program scene, then enforces stacking order (array order, bottom →
    /// top) and visibility — re-running resets the recommended layout.
    /// `reroute_audio` = the "Control audio via OBS" checkbox, required to
    /// get the stream's audio into the OBS mixer; `shutdown` unloads hidden
    /// sources so they don't hold WHEP connections.
    static func ensureBrowserSources(password: String?, sources: [BrowserSource]) async throws {
        let client = OBSWebSocketClient()
        defer { client.close() }
        try await client.identify(password: password)

        let sceneResponse = try await client.request("GetCurrentProgramScene")
        guard let sceneName = (sceneResponse["currentProgramSceneName"] ?? sceneResponse["sceneName"]) as? String else {
            throw OBSError.requestFailed("GetCurrentProgramScene", -1)
        }

        for (index, source) in sources.enumerated() {
            let settings: [String: Any] = [
                "url": source.url,
                "width": 1920,
                "height": 1080,
                "reroute_audio": true,
                "shutdown": true,
            ]
            do {
                _ = try await client.request("CreateInput", [
                    "sceneName": sceneName,
                    "inputName": source.name,
                    "inputKind": "browser_source",
                    "inputSettings": settings,
                    "sceneItemEnabled": source.visible,
                ])
            } catch OBSError.requestFailed(_, 601) {
                // ResourceAlreadyExists — refresh the existing source's
                // settings instead (covers URL/credential changes).
                _ = try await client.request("SetInputSettings", [
                    "inputName": source.name,
                    "inputSettings": settings,
                    "overlay": true,
                ])
            }

            guard let itemID = try await client.request("GetSceneItemId", [
                "sceneName": sceneName,
                "sourceName": source.name,
            ])["sceneItemId"] as? Int else { continue }
            _ = try await client.request("SetSceneItemEnabled", [
                "sceneName": sceneName,
                "sceneItemId": itemID,
                "sceneItemEnabled": source.visible,
            ])
            _ = try await client.request("SetSceneItemIndex", [
                "sceneName": sceneName,
                "sceneItemId": itemID,
                "sceneItemIndex": index,
            ])
        }
    }

    // MARK: - Protocol plumbing

    private func identify(password: String?) async throws {
        let hello: [String: Any]
        do {
            hello = try await receiveJSON()
        } catch {
            throw OBSError.notRunning
        }
        guard let helloData = hello["d"] as? [String: Any] else { throw OBSError.notRunning }

        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
        if let auth = helloData["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String {
            guard let password, !password.isEmpty else { throw OBSError.authRequired }
            // base64(sha256(base64(sha256(password + salt)) + challenge))
            let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
            identify["authentication"] = Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
        }
        try await sendJSON(["op": 1, "d": identify])

        do {
            let identified = try await receiveJSON()
            guard identified["op"] as? Int == 2 else { throw OBSError.authFailed }
        } catch {
            // OBS closes the socket on bad auth rather than replying.
            throw OBSError.authFailed
        }
    }

    private func request(_ type: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
        let requestID = UUID().uuidString
        try await sendJSON(["op": 6, "d": ["requestType": type, "requestId": requestID, "requestData": data]])
        while true {
            let message = try await receiveJSON()
            guard message["op"] as? Int == 7,
                  let body = message["d"] as? [String: Any],
                  body["requestId"] as? String == requestID else { continue }
            let status = body["requestStatus"] as? [String: Any]
            if status?["result"] as? Bool == true {
                return body["responseData"] as? [String: Any] ?? [:]
            }
            throw OBSError.requestFailed(type, status?["code"] as? Int ?? -1)
        }
    }

    private func receiveJSON() async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
