import Foundation
@preconcurrency import Security

/// HTTP/HTTPS client for GameStream server communication.
/// Handles server info, app list, launch/quit, and pairing HTTP endpoints.
actor NvHTTPClient {
    let hostname: String
    let httpPort: UInt16
    private(set) var httpsPort: UInt16

    private let cryptoManager: CryptoManager
    private var httpSession: URLSession
    private var httpsSession: URLSession?
    private var tlsDelegate: TLSSessionDelegate?
    private var serverCertDER: Data?

    /// Fixed unique ID shared across all Moonlight clients
    private static let uniqueId = "0123456789ABCDEF"
    private static let deviceName = "roth"

    init(hostname: String, httpPort: UInt16 = 47989, httpsPort: UInt16 = 47984, cryptoManager: CryptoManager = .shared) {
        self.hostname = hostname
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.cryptoManager = cryptoManager

        // Plain HTTP session (no TLS)
        let httpConfig = URLSessionConfiguration.ephemeral
        httpConfig.timeoutIntervalForRequest = 5
        httpConfig.httpShouldSetCookies = false
        self.httpSession = URLSession(configuration: httpConfig)
    }

    /// Configure HTTPS session with client cert and pinned server cert
    func setServerCert(_ certDER: Data) async throws {
        self.serverCertDER = certDER
        let identity = try await cryptoManager.getClientSecIdentity()
        let clientCert = try await cryptoManager.getClientSecCertificate()

        let delegate = TLSSessionDelegate(
            clientIdentity: identity,
            clientCert: clientCert,
            pinnedServerCertDER: certDER
        )
        self.tlsDelegate = delegate

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.httpShouldSetCookies = false
        self.httpsSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func updateHttpsPort(_ port: UInt16) {
        self.httpsPort = port
    }

    // MARK: - Server Info

    func getServerInfo() async throws -> ServerInfo {
        // Use HTTPS if we have a server cert, otherwise HTTP
        let data: Data
        if serverCertDER != nil, let session = httpsSession {
            do {
                data = try await rawRequest("serverinfo", session: session, useHTTPS: true)
            } catch {
                // Fall back to HTTP on cert errors
                data = try await rawRequest("serverinfo", session: httpSession, useHTTPS: false)
            }
        } else {
            data = try await rawRequest("serverinfo", session: httpSession, useHTTPS: false)
        }

        // Parse with display mode-aware parser
        let result = ServerInfoXMLParser().parse(data: data)
        let xml = result.xml
        try xml.verifyStatus()

        var info = ServerInfo()
        info.hostname = xml.elements["hostname"] ?? ""
        info.uuid = xml.elements["uniqueid"] ?? ""
        info.mac = xml.elements["mac"] ?? ""
        info.localAddress = xml.elements["LocalIP"] ?? ""
        info.remoteAddress = xml.elements["ExternalIP"] ?? ""
        info.pairStatus = xml.elements["PairStatus"] == "1"
        info.currentGameId = Int(xml.elements["currentgame"] ?? "0") ?? 0
        info.appVersion = xml.elements["appversion"] ?? ""
        info.gfeVersion = xml.elements["GfeVersion"] ?? ""
        info.gpuModel = xml.elements["gputype"] ?? ""
        info.serverCodecModeSupport = Int(xml.elements["ServerCodecModeSupport"] ?? "1") ?? 1
        info.maxLumaPixelsHEVC = Int(xml.elements["MaxLumaPixelsHEVC"] ?? "0") ?? 0
        info.displayModes = result.displayModes

        if let portStr = xml.elements["HttpsPort"], let port = UInt16(portStr), port > 0 {
            info.httpsPort = port
            if self.httpsPort != port {
                self.httpsPort = port
            }
        }

        if let state = xml.elements["state"] {
            info.isNvidiaServerSoftware = state.contains("MJOLNIR")
        }

        return info
    }

    // MARK: - App List

    func getAppList() async throws -> [MoonlightApp] {
        guard let session = httpsSession else { throw MoonlightError.notPaired }

        let data = try await rawRequest("applist", session: session, useHTTPS: true)

        // Parse app list XML with specialized parser
        let parser = AppListXMLParser()
        return parser.parse(data: data)
    }

    // MARK: - Launch / Resume / Quit

    func launchApp(appId: Int, width: Int, height: Int, fps: Int,
                   bitrate: Int, riKey: Data, riKeyId: Int32,
                   localAudioPlayMode: Bool, surroundAudioInfo: Int,
                   supportedVideoFormats: Int, optimizeGameSettings: Bool) async throws -> String {
        guard let session = httpsSession else { throw MoonlightError.notPaired }

        var args: [(String, String)] = [
            ("appid", String(appId)),
            ("mode", "\(width)x\(height)x\(fps)"),
            ("additionalStates", "1"),
            ("sops", optimizeGameSettings ? "1" : "0"),
            ("rikey", riKey.hexString),
            ("rikeyid", String(riKeyId)),
            ("localAudioPlayMode", localAudioPlayMode ? "1" : "0"),
            ("surroundAudioInfo", String(surroundAudioInfo)),
            ("remoteControllersBitmap", "0"),
            ("gcmap", "0"),
        ]

        // Add HDR params if 10-bit formats are in the supported list
        if supportedVideoFormats & (ServerCodecMode.hevcMain10 | ServerCodecMode.av1Main10) != 0 {
            args.append(("hdrMode", "1"))
            args.append(("clientHdrCapVersion", "0"))
            args.append(("clientHdrCapSupportedFlagsInUint32", "0"))
            args.append(("clientHdrCapMetaDataId", "NV_STATIC_METADATA_TYPE_1"))
            args.append(("clientHdrCapDisplayData", "0x0x0x0x0x0x0x0x0x0x0"))
        }

        let xml = try await request("launch", args: args, session: session, useHTTPS: true, timeout: 120)
        try xml.verifyStatus()

        guard let sessionUrl = xml.elements["sessionUrl0"] else {
            throw MoonlightError.invalidResponse
        }
        return sessionUrl
    }

    func resumeApp(riKey: Data, riKeyId: Int32, surroundAudioInfo: Int) async throws -> String {
        guard let session = httpsSession else { throw MoonlightError.notPaired }

        let args: [(String, String)] = [
            ("rikey", riKey.hexString),
            ("rikeyid", String(riKeyId)),
            ("surroundAudioInfo", String(surroundAudioInfo)),
        ]

        let xml = try await request("resume", args: args, session: session, useHTTPS: true, timeout: 30)
        try xml.verifyStatus()

        guard let sessionUrl = xml.elements["sessionUrl0"] else {
            throw MoonlightError.invalidResponse
        }
        return sessionUrl
    }

    func quitApp() async throws {
        guard let session = httpsSession else { throw MoonlightError.notPaired }

        let xml = try await request("cancel", session: session, useHTTPS: true, timeout: 30)
        try xml.verifyStatus()
    }

    // MARK: - Pairing Endpoints (called by NvPairingManager)

    /// Send a pairing request. Returns parsed XML elements.
    /// Pass `timeout: nil` for the default (5s), or `timeout: 0` for indefinite wait (getservercert).
    /// Pass `useHTTPS: true` for the final pair challenge (step 6).
    func pairRequest(args: [(String, String)], timeout: TimeInterval? = nil, useHTTPS: Bool = false) async throws -> XMLResponse {
        var allArgs = [("devicename", Self.deviceName), ("updateState", "1")]
        allArgs.append(contentsOf: args)

        // timeout 0 means "wait indefinitely" (server blocks until user enters PIN)
        let effectiveTimeout: TimeInterval = timeout == 0 ? 300 : (timeout ?? 5)
        let session = useHTTPS ? (httpsSession ?? httpSession) : httpSession
        return try await request("pair", args: allArgs, session: session, useHTTPS: useHTTPS, timeout: effectiveTimeout)
    }

    func unpair() async throws {
        _ = try await request("unpair", session: httpSession, useHTTPS: false)
    }

    // MARK: - HTTP Internals

    private func request(_ command: String, args: [(String, String)] = [], session: URLSession,
                         useHTTPS: Bool, timeout: TimeInterval = 5) async throws -> XMLResponse {
        let data = try await rawRequest(command, args: args, session: session, useHTTPS: useHTTPS, timeout: timeout)
        let xml = SimpleXMLParser().parse(data: data)
        return xml
    }

    private func rawRequest(_ command: String, args: [(String, String)] = [], session: URLSession,
                            useHTTPS: Bool, timeout: TimeInterval = 5) async throws -> Data {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? httpsPort : httpPort

        var components = URLComponents()
        components.scheme = scheme
        components.host = hostname
        components.port = Int(port)
        components.path = "/\(command)"

        // Standard query parameters
        var queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.uniqueId),
            URLQueryItem(name: "uuid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
        ]
        for (key, value) in args {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw MoonlightError.networkError(URLError(.badURL))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout

        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse {
            guard httpResponse.statusCode != 401 else {
                throw MoonlightError.notPaired
            }
        }

        return data
    }
}

// MARK: - TLS Session Delegate

/// Handles client certificate authentication and server certificate pinning.
private final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    let clientIdentity: SecIdentity
    let clientCert: SecCertificate
    let pinnedServerCertDER: Data

    init(clientIdentity: SecIdentity, clientCert: SecCertificate, pinnedServerCertDER: Data) {
        self.clientIdentity = clientIdentity
        self.clientCert = clientCert
        self.pinnedServerCertDER = pinnedServerCertDER
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            let credential = URLCredential(
                identity: clientIdentity,
                certificates: [clientCert],
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } else if method == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // Check if server cert matches our pinned cert
            if let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
               let serverCert = chain.first {
                let serverCertData = SecCertificateCopyData(serverCert) as Data
                if serverCertData == pinnedServerCertDER {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
            }

            // Accept self-signed certs from GameStream servers
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - XML Parsing

struct XMLResponse: Sendable {
    let elements: [String: String]
    let rootAttributes: [String: String]

    nonisolated func verifyStatus() throws {
        guard let statusStr = rootAttributes["status_code"] else {
            throw MoonlightError.invalidResponse
        }

        // Parse as unsigned first (GFE can return 0xFFFFFFFF), then check for 200
        let status: Int
        if let unsigned = UInt32(statusStr) {
            status = Int(Int32(bitPattern: unsigned))
        } else if let signed = Int(statusStr) {
            status = signed
        } else {
            throw MoonlightError.invalidResponse
        }

        guard status == 200 else {
            let message = rootAttributes["status_message"] ?? elements["status_message"] ?? "Unknown error (code: \(status))"
            throw MoonlightError.serverError(message)
        }
    }
}

/// SAX-style XML parser that extracts flat key-value pairs from XML elements.
private class SimpleXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var elements: [String: String] = [:]
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""

    nonisolated func parse(data: Data) -> XMLResponse {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return XMLResponse(elements: elements, rootAttributes: rootAttributes)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if !currentText.isEmpty {
            elements[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentElement = nil
    }
}

/// Parses the /serverinfo XML response, including flat key-value elements and nested <DisplayMode> entries.
private class ServerInfoXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var elements: [String: String] = [:]
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]
    private nonisolated(unsafe) var displayModes: [DisplayMode] = []
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""
    private nonisolated(unsafe) var insideDisplayMode = false
    private nonisolated(unsafe) var currentWidth: Int = 0
    private nonisolated(unsafe) var currentHeight: Int = 0
    private nonisolated(unsafe) var currentRefreshRate: Int = 0

    struct Result {
        let xml: XMLResponse
        let displayModes: [DisplayMode]
    }

    nonisolated func parse(data: Data) -> Result {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Result(
            xml: XMLResponse(elements: elements, rootAttributes: rootAttributes),
            displayModes: displayModes
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        } else if elementName == "DisplayMode" {
            insideDisplayMode = true
            currentWidth = 0
            currentHeight = 0
            currentRefreshRate = 0
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideDisplayMode {
            switch elementName {
            case "Width": currentWidth = Int(trimmed) ?? 0
            case "Height": currentHeight = Int(trimmed) ?? 0
            case "RefreshRate": currentRefreshRate = Int(trimmed) ?? 0
            case "DisplayMode":
                if currentWidth > 0 && currentHeight > 0 && currentRefreshRate > 0 {
                    displayModes.append(DisplayMode(
                        width: currentWidth,
                        height: currentHeight,
                        refreshRate: currentRefreshRate
                    ))
                }
                insideDisplayMode = false
            default: break
            }
        } else if !trimmed.isEmpty {
            elements[elementName] = trimmed
        }

        currentElement = nil
    }
}

/// Parses the /applist XML response containing multiple <App> elements.
private class AppListXMLParser: NSObject, XMLParserDelegate {
    private nonisolated(unsafe) var apps: [MoonlightApp] = []
    private nonisolated(unsafe) var currentAppId: Int = 0
    private nonisolated(unsafe) var currentAppName: String = ""
    private nonisolated(unsafe) var currentHdr: Bool = false
    private nonisolated(unsafe) var currentCollector: Bool = false
    private nonisolated(unsafe) var insideApp = false
    private nonisolated(unsafe) var currentElement: String?
    private nonisolated(unsafe) var currentText: String = ""
    private nonisolated(unsafe) var rootAttributes: [String: String] = [:]

    nonisolated func parse(data: Data) -> [MoonlightApp] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        // Verify status first
        if let statusStr = rootAttributes["status_code"],
           let status = Int(statusStr), status != 200 {
            return []
        }

        return apps
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "root" {
            rootAttributes = attributes
        } else if elementName == "App" {
            insideApp = true
            currentAppId = 0
            currentAppName = ""
            currentHdr = false
            currentCollector = false
        }
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideApp {
            switch elementName {
            case "AppTitle": currentAppName = trimmed
            case "ID": currentAppId = Int(trimmed) ?? 0
            case "IsHdrSupported": currentHdr = trimmed == "1"
            case "IsAppCollectorGame": currentCollector = trimmed == "1"
            case "App":
                if currentAppId != 0 && !currentAppName.isEmpty {
                    apps.append(MoonlightApp(
                        id: currentAppId,
                        name: currentAppName,
                        hdrSupported: currentHdr,
                        isAppCollectorGame: currentCollector
                    ))
                }
                insideApp = false
            default: break
            }
        }

        currentElement = nil
    }
}
