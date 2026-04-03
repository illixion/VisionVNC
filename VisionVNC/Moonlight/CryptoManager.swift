import Foundation
import Security
import CommonCrypto

actor CryptoManager {
    static let shared = CryptoManager()

    private static let keyTag = "com.visionvnc.moonlight.clientkey"
    private static let certDefaultsKey = "moonlight_client_cert_der"

    private var cachedPrivateKey: SecKey?
    private var cachedCertDER: Data?

    // MARK: - Client Identity

    /// Returns (privateKey, certificateDER). Generates and persists if needed.
    func getOrCreateIdentity() throws -> (privateKey: SecKey, certDER: Data) {
        if let key = cachedPrivateKey, let cert = cachedCertDER {
            return (key, cert)
        }

        // Try loading from Keychain / UserDefaults
        if let key = loadPrivateKey(), let cert = loadCertDER() {
            cachedPrivateKey = key
            cachedCertDER = cert
            return (key, cert)
        }

        // Generate new identity
        let (key, cert) = try generateIdentity()
        cachedPrivateKey = key
        cachedCertDER = cert
        return (key, cert)
    }

    func getClientCertPEM() throws -> String {
        let (_, certDER) = try getOrCreateIdentity()
        return Self.certDERToPEM(certDER)
    }

    func signWithClientKey(_ data: Data) throws -> Data {
        let (privateKey, _) = try getOrCreateIdentity()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw MoonlightError.cryptoError("RSA signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return signature
    }

    func getClientCertDER() throws -> Data {
        let (_, certDER) = try getOrCreateIdentity()
        return certDER
    }

    func getClientSecIdentity() throws -> SecIdentity {
        let (_, certDER) = try getOrCreateIdentity()

        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw MoonlightError.cryptoError("Failed to create SecCertificate from DER")
        }

        // Try to find identity in Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let identity = result {
            return (identity as! SecIdentity)
        }

        // If identity query fails, try adding the cert to Keychain and retry
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: "VisionVNC Moonlight Client",
        ]
        SecItemAdd(certAddQuery as CFDictionary, nil) // ignore duplicate error

        let status2 = SecItemCopyMatching(query as CFDictionary, &result)
        if status2 == errSecSuccess, let identity = result {
            return (identity as! SecIdentity)
        }

        throw MoonlightError.cryptoError("Failed to create SecIdentity (status: \(status2))")
    }

    func getClientSecCertificate() throws -> SecCertificate {
        let (_, certDER) = try getOrCreateIdentity()
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw MoonlightError.cryptoError("Failed to create SecCertificate")
        }
        return cert
    }

    // MARK: - Key/Cert Persistence

    private func generateIdentity() throws -> (SecKey, Data) {
        // Delete any existing key
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Generate RSA 2048 key pair, stored permanently in Keychain
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightError.cryptoError("Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw MoonlightError.cryptoError("Failed to extract public key")
        }

        // Export public key as PKCS#1 DER
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw MoonlightError.cryptoError("Failed to export public key")
        }

        // Build self-signed X.509 certificate
        let certDER = try buildSelfSignedCert(publicKeyDER: publicKeyDER, privateKey: privateKey)

        // Store cert DER in UserDefaults
        UserDefaults.standard.set(certDER, forKey: Self.certDefaultsKey)

        // Add certificate to Keychain for SecIdentity linking
        if let certificate = SecCertificateCreateWithData(nil, certDER as CFData) {
            let certAddQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: "VisionVNC Moonlight Client",
            ]
            SecItemAdd(certAddQuery as CFDictionary, nil)
        }

        return (privateKey, certDER)
    }

    private func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    private func loadCertDER() -> Data? {
        UserDefaults.standard.data(forKey: Self.certDefaultsKey)
    }

    // MARK: - X.509 Certificate Builder

    private func buildSelfSignedCert(publicKeyDER: Data, privateKey: SecKey) throws -> Data {
        let now = Date()
        let twentyYears = TimeInterval(60 * 60 * 24 * 365 * 20)
        let notAfter = now.addingTimeInterval(twentyYears)

        // Signature algorithm identifier
        let sigAlgId = ASN1.sequence(ASN1.oid(ASN1.sha256WithRSAEncryption) + ASN1.null())

        // Subject/Issuer: CN=NVIDIA GameStream Client
        let cnAttr = ASN1.sequence(ASN1.oid(ASN1.commonName) + ASN1.utf8String("NVIDIA GameStream Client"))
        let name = ASN1.sequence(ASN1.set(cnAttr))

        // Subject Public Key Info: wrap PKCS#1 key in SubjectPublicKeyInfo
        let spki = ASN1.sequence(
            ASN1.sequence(ASN1.oid(ASN1.rsaEncryption) + ASN1.null()) +
            ASN1.bitString(publicKeyDER)
        )

        // TBS Certificate
        var tbsContent = Data()
        tbsContent.append(ASN1.contextExplicit(0, ASN1.integer(2))) // version v3
        tbsContent.append(ASN1.integer(0))                          // serialNumber
        tbsContent.append(sigAlgId)                                   // signature algorithm
        tbsContent.append(name)                                       // issuer
        tbsContent.append(ASN1.sequence(ASN1.utcTime(now) + ASN1.utcTime(notAfter))) // validity
        tbsContent.append(name)                                       // subject
        tbsContent.append(spki)                                       // subjectPublicKeyInfo

        let tbsCert = ASN1.sequence(tbsContent)

        // Sign TBS with private key (SHA-256 + RSA PKCS#1 v1.5)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCert as CFData,
            &error
        ) as Data? else {
            throw MoonlightError.cryptoError("Certificate signing failed")
        }

        // Full certificate: TBS + algorithm + signature
        return ASN1.sequence(tbsCert + sigAlgId + ASN1.bitString(signature))
    }

    // MARK: - Static Crypto Operations

    static func aesEncryptECB(_ data: Data, key: Data) throws -> Data {
        try aesECB(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func aesDecryptECB(_ data: Data, key: Data) throws -> Data {
        try aesECB(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func aesECB(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var outBuffer = [UInt8](repeating: 0, count: bufferSize)
        var outLength: Int = 0

        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, key.count,
                    nil, // no IV for ECB
                    dataPtr.baseAddress, data.count,
                    &outBuffer, bufferSize,
                    &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw MoonlightError.cryptoError("AES-ECB failed with status \(status)")
        }

        return Data(outBuffer.prefix(outLength))
    }

    static func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    static func sha1(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    static func verifySignature(_ data: Data, signature: Data, publicKey: SecKey) -> Bool {
        SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            nil
        )
    }

    /// Extract the raw signature bytes from a DER-encoded X.509 certificate
    static func extractSignatureFromCert(_ certDER: Data) -> Data? {
        let bytes = Array(certDER)
        guard bytes.count > 2, bytes[0] == 0x30 else { return nil }

        // Parse outer SEQUENCE
        guard let (_, outerStart) = parseTagLength(bytes, offset: 0) else { return nil }
        var offset = outerStart

        // Skip TBS Certificate (first SEQUENCE)
        guard let (tbsLen, tbsStart) = parseTagLength(bytes, offset: offset) else { return nil }
        offset = tbsStart + tbsLen

        // Skip Signature Algorithm (second SEQUENCE)
        guard let (algLen, algStart) = parseTagLength(bytes, offset: offset) else { return nil }
        offset = algStart + algLen

        // Read Signature (BIT STRING: tag 0x03)
        guard offset < bytes.count, bytes[offset] == 0x03 else { return nil }
        guard let (sigLen, sigStart) = parseTagLength(bytes, offset: offset) else { return nil }

        // BIT STRING content: first byte is unused bits count (0x00), rest is signature
        let dataStart = sigStart + 1
        let dataEnd = sigStart + sigLen
        guard dataStart < dataEnd, dataEnd <= bytes.count else { return nil }

        return Data(bytes[dataStart..<dataEnd])
    }

    private static func parseTagLength(_ bytes: [UInt8], offset: Int) -> (contentLength: Int, contentStart: Int)? {
        guard offset + 1 < bytes.count else { return nil }
        var pos = offset + 1 // skip tag

        let firstLen = bytes[pos]
        pos += 1

        let length: Int
        if firstLen < 128 {
            length = Int(firstLen)
        } else {
            let numBytes = Int(firstLen & 0x7F)
            guard pos + numBytes <= bytes.count else { return nil }
            var len = 0
            for i in 0..<numBytes {
                len = (len << 8) | Int(bytes[pos + i])
            }
            pos += numBytes
            length = len
        }

        return (length, pos)
    }

    // MARK: - PEM Conversion

    static func certDERToPEM(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func pemToCertDER(_ pem: String) -> Data? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: stripped)
    }

    // MARK: - Random Bytes

    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return bytes
    }
}

// MARK: - ASN.1 DER Builder

private enum ASN1 {
    // Well-known OIDs
    nonisolated(unsafe) static let sha256WithRSAEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    nonisolated(unsafe) static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    nonisolated(unsafe) static let commonName: [UInt8] = [0x55, 0x04, 0x03]

    nonisolated static func wrap(tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: lengthBytes(content.count))
        result.append(content)
        return result
    }

    nonisolated static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    nonisolated static func sequence(_ content: Data) -> Data { wrap(tag: 0x30, content) }
    nonisolated static func set(_ content: Data) -> Data { wrap(tag: 0x31, content) }
    nonisolated static func null() -> Data { Data([0x05, 0x00]) }
    nonisolated static func oid(_ bytes: [UInt8]) -> Data { wrap(tag: 0x06, Data(bytes)) }
    nonisolated static func utf8String(_ string: String) -> Data { wrap(tag: 0x0C, Data(string.utf8)) }

    nonisolated static func bitString(_ content: Data) -> Data {
        var inner = Data([0x00]) // 0 unused bits
        inner.append(content)
        return wrap(tag: 0x03, inner)
    }

    nonisolated static func integer(_ value: Int) -> Data {
        if value == 0 {
            return wrap(tag: 0x02, Data([0x00]))
        }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return wrap(tag: 0x02, Data(bytes))
    }

    nonisolated static func contextExplicit(_ tag: UInt8, _ content: Data) -> Data {
        wrap(tag: 0xA0 | tag, content)
    }

    nonisolated static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return wrap(tag: 0x17, Data(formatter.string(from: date).utf8))
    }
}
