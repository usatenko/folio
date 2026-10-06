import Foundation
import Security

/// Creates the OAuth key material in-app: two RSA 2048 pairs and the Diffie-Hellman parameters.
/// Private keys come out as PKCS#1 PEM (what `openssl genrsa` writes), public keys as SubjectPublicKeyInfo
/// PEM (what `openssl rsa -pubout` writes), so the portal sees exactly the files its instructions describe.
enum KeyGen {
    struct Generated {
        let signaturePrivatePEM: String
        let signaturePublicPEM: String
        let encryptionPrivatePEM: String
        let encryptionPublicPEM: String
        let dhParamsPEM: String

        /// The three files the portal asks for, in the order its form lists them.
        var publicFiles: [(name: String, contents: String)] {
            [("signature.pub.pem", signaturePublicPEM), ("encryption.pub.pem", encryptionPublicPEM), ("dhparam.pem", dhParamsPEM)]
        }
    }

    /// RSA pairs are instant; the DH parameters come from `openssl dhparam 2048` (the documented procedure,
    /// about a minute) with the standard group as a fallback if openssl is unavailable.
    static func generate() async throws -> Generated {
        let sig = try rsaPair()
        let enc = try rsaPair()
        let dh = (try? await opensslDHParams()) ?? dhParamsPEM()
        return Generated(signaturePrivatePEM: sig.privatePEM, signaturePublicPEM: sig.publicPEM,
                         encryptionPrivatePEM: enc.privatePEM, encryptionPublicPEM: enc.publicPEM,
                         dhParamsPEM: dh)
    }

    /// `/usr/bin/openssl dhparam 2048`: a fresh safe prime with 2 as a full generator, exactly what IBKR's
    /// instructions tell users to create. The child process inherits the app sandbox, which is fine here.
    static func opensslDHParams() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            proc.arguments = ["dhparam", "2048"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            proc.terminationHandler = { p in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0, text.contains("BEGIN DH PARAMETERS") {
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: CryptoError.key("openssl dhparam failed (\(p.terminationStatus))"))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Nine uppercase letters, the format the portal requires for a consumer key.
    static func suggestedConsumerKey() -> String {
        String((0..<9).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement()! })
    }

    static func rsaPair() throws -> (privatePEM: String, publicPEM: String) {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let priv = SecKeyCopyExternalRepresentation(key, &err) as Data?,
              let pub = SecKeyCopyPublicKey(key),
              let pubPKCS1 = SecKeyCopyExternalRepresentation(pub, &err) as Data?
        else { throw CryptoError.key("key generation failed: \(err?.takeRetainedValue().localizedDescription ?? "?")") }
        return (pem("RSA PRIVATE KEY", priv), pem("PUBLIC KEY", DEREncode.subjectPublicKeyInfo(rsaPKCS1: pubPKCS1)))
    }

    /// Fallback: RFC 3526 group 14, the standard 2048-bit MODP safe prime with generator 2 (which generates
    /// the prime-order subgroup rather than the full group; valid for the exchange, but `openssl dhparam -check`
    /// warns about it, so the openssl-generated parameters above are preferred).
    static let dhPrimeHex = """
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
    EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
    EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
    83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
    E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510\
    15728E5A8AACAA68FFFFFFFFFFFFFFFF
    """

    static func dhParamsPEM() -> String {
        let p = Data(hex: dhPrimeHex)!
        return pem("DH PARAMETERS", DEREncode.sequence([DEREncode.integer(p), DEREncode.integer(Data([2]))]))
    }

    /// Public SPKI PEM derived from a PKCS#1 private PEM (to rebuild the upload files when resuming).
    static func publicPEM(forPrivate privatePEM: String) -> String {
        guard let key = try? RSA.privateKey(pem: privatePEM), let pub = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return "" }
        return pem("PUBLIC KEY", DEREncode.subjectPublicKeyInfo(rsaPKCS1: pkcs1))
    }

    static func pem(_ label: String, _ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }
}

/// Just enough DER encoding for the structures above.
enum DEREncode {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes = withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) }
            while bytes.first == 0 { bytes.removeFirst() }
            out.append(0x80 | UInt8(bytes.count))
            out.append(bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }

    /// Unsigned big-endian magnitude as a DER INTEGER (leading zero added when the top bit is set).
    static func integer(_ magnitude: Data) -> Data {
        var m = magnitude
        while m.count > 1, m.first == 0 { m.removeFirst() }
        if let first = m.first, first & 0x80 != 0 { m.insert(0, at: 0) }
        return tlv(0x02, m)
    }

    static func subjectPublicKeyInfo(rsaPKCS1: Data) -> Data {
        let rsaEncryptionOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        let algorithm = sequence([rsaEncryptionOID, Data([0x05, 0x00])])
        let bitString = tlv(0x03, Data([0x00]) + rsaPKCS1)
        return sequence([algorithm, bitString])
    }
}
