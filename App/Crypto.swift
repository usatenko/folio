import BigInt
import CryptoKit
import Foundation
import Security

enum CryptoError: LocalizedError {
    case pem(String), der(String), key(String)
    var errorDescription: String? {
        switch self {
        case .pem(let s), .der(let s), .key(let s): s
        }
    }
}

enum PEM {
    /// Returns the label ("RSA PRIVATE KEY", "DH PARAMETERS", …) and the DER bytes of the first PEM block.
    static func decode(_ text: String) throws -> (label: String, der: Data) {
        var label = ""
        var body = ""
        var inside = false
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("-----BEGIN ") {
                label = String(l.dropFirst(11).dropLast(5))
                inside = true
            } else if l.hasPrefix("-----END ") {
                break
            } else if inside, !l.isEmpty {
                body += l
            }
        }
        guard inside, let der = Data(base64Encoded: body) else { throw CryptoError.pem("not a PEM file") }
        return (label, der)
    }
}

/// Minimal DER reader: enough for DH parameters and PKCS#8 unwrapping.
enum DER {
    struct Node {
        let tag: UInt8
        let content: Data
    }

    static func children(of sequence: Data) throws -> [Node] {
        let outer = try read(sequence, at: 0).node
        guard outer.tag == 0x30 else { throw CryptoError.der("expected SEQUENCE") }
        var nodes: [Node] = []
        var i = outer.content.startIndex
        while i < outer.content.endIndex {
            let r = try read(outer.content, at: i)
            nodes.append(r.node)
            i = r.next
        }
        return nodes
    }

    private static func read(_ d: Data, at start: Data.Index) throws -> (node: Node, next: Data.Index) {
        guard start + 2 <= d.endIndex else { throw CryptoError.der("truncated") }
        let tag = d[start]
        var i = start + 1
        var len = Int(d[i])
        i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n <= 4, i + n <= d.endIndex else { throw CryptoError.der("bad length") }
            len = 0
            for _ in 0..<n {
                len = len << 8 | Int(d[i])
                i += 1
            }
        }
        guard i + len <= d.endIndex else { throw CryptoError.der("truncated content") }
        return (Node(tag: tag, content: d[i..<(i + len)]), i + len)
    }
}

enum RSA {
    static func privateKey(pem: String) throws -> SecKey {
        let (label, raw) = try PEM.decode(pem)
        var der = raw
        if label == "PRIVATE KEY" {  // PKCS#8: unwrap to the PKCS#1 key inside the OCTET STRING
            let parts = try DER.children(of: raw)
            guard parts.count >= 3, parts[2].tag == 0x04 else { throw CryptoError.der("unexpected PKCS#8 layout") }
            der = Data(parts[2].content)
        }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            throw CryptoError.key("cannot read RSA key: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    static func decryptPKCS1(_ data: Data, with key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, data as CFData, &err) else {
            throw CryptoError.key("RSA decrypt failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return out as Data
    }

    static func signSHA256(_ message: Data, with key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &err) else {
            throw CryptoError.key("RSA sign failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return sig as Data
    }
}

enum DH {
    /// Prime and generator from a "DH PARAMETERS" PEM (SEQUENCE { prime INTEGER, generator INTEGER }).
    static func params(pem: String) throws -> (prime: BigUInt, generator: BigUInt) {
        let (label, der) = try PEM.decode(pem)
        guard label == "DH PARAMETERS" else { throw CryptoError.pem("expected DH PARAMETERS, got \(label)") }
        let parts = try DER.children(of: der)
        guard parts.count >= 2, parts[0].tag == 0x02, parts[1].tag == 0x02 else { throw CryptoError.der("malformed DH parameters") }
        return (BigUInt(Data(parts[0].content)), BigUInt(Data(parts[1].content)))
    }

    static func prime(pem: String) throws -> BigUInt { try params(pem: pem).prime }

    /// Big-endian bytes with a leading zero when the top bit would otherwise read as a sign bit
    /// (Java BigInteger.toByteArray semantics, which IBKR's HMAC key derivation relies on).
    static func signedBytes(_ x: BigUInt) -> Data {
        var bytes = x.serialize()
        if x.bitWidth % 8 == 0 { bytes.insert(0, at: 0) }
        return bytes
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        var s = Substring(hex.count % 2 == 0 ? hex : "0" + hex)
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        while !s.isEmpty {
            guard let b = UInt8(s.prefix(2), radix: 16) else { return nil }
            bytes.append(b)
            s = s.dropFirst(2)
        }
        self.init(bytes)
    }
}

extension String {
    /// Python's urllib.parse.quote_plus: everything but unreserved characters is percent-encoded, space becomes '+'.
    var quotedPlus: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_.-~")
        return addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
    }
}
