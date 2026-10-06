import BigInt
import CryptoKit
import Foundation
import Security

enum IBKRError: LocalizedError {
    case http(Int, String), badResponse(String), sessionTokenMismatch
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "IBKR HTTP \(code): \(body.prefix(300))"
        case .badResponse(let s): "unexpected IBKR response: \(s.prefix(200))"
        case .sessionTokenMismatch: "live session token validation failed; check the keys and consumer key"
        }
    }
}

/// IBKR Web API over OAuth 1.0a, read-only: it never opens a brokerage session, so TWS and the
/// mobile app stay connected. Port of ibind's oauth1a flow.
actor IBKRClient {
    static let baseURL = "https://api.ibkr.com/v1/api/"
    private static let realm = "limited_poa"

    private let credentials: Credentials
    private let signatureKey: SecKey
    private let encryptionKey: SecKey
    private let dhPrime: BigUInt
    private let dhGenerator: BigUInt
    private var liveSessionToken: Data?
    private var liveSessionExpires = Date.distantPast
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    init(credentials: Credentials) throws {
        self.credentials = credentials
        signatureKey = try RSA.privateKey(pem: credentials.signatureKeyPEM)
        encryptionKey = try RSA.privateKey(pem: credentials.encryptionKeyPEM)
        (dhPrime, dhGenerator) = try DH.params(pem: credentials.dhParamsPEM)
    }

    // MARK: endpoints

    func accounts() async throws -> [[String: Any]] { try await get("portfolio/accounts") as? [[String: Any]] ?? [] }
    func summary(_ acct: String) async throws -> [String: Any] { try await get("portfolio/\(acct)/summary") as? [String: Any] ?? [:] }
    func ledger(_ acct: String) async throws -> [String: Any] { try await get("portfolio/\(acct)/ledger") as? [String: Any] ?? [:] }
    func positions(_ acct: String) async throws -> [[String: Any]] { try await get("portfolio/\(acct)/positions/0") as? [[String: Any]] ?? [] }
    func allPeriods(_ acct: String) async throws -> [String: Any] {
        try await post("pa/allperiods", json: ["acctIds": [acct]]) as? [String: Any] ?? [:]
    }

    // MARK: transport

    func get(_ path: String) async throws -> Any { try await request("GET", path, body: nil) }
    func post(_ path: String, json: Any) async throws -> Any { try await request("POST", path, body: json) }

    private func request(_ method: String, _ path: String, body: Any?, retrying: Bool = false) async throws -> Any {
        if liveSessionToken == nil || Date.now >= liveSessionExpires {
            try await requestLiveSessionToken()
        }
        let url = Self.baseURL + path
        var params = oauthParams(signatureMethod: "HMAC-SHA256")
        let base = baseString(method: method, url: url, params: params, prepend: nil)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(base.utf8), using: SymmetricKey(data: liveSessionToken!))
        params["oauth_signature"] = Data(mac).base64EncodedString().quotedPlus

        let (data, status) = try await send(method: method, url: url, params: params, body: body)
        if status == 401, !retrying {
            liveSessionToken = nil
            return try await request(method, path, body: body, retrying: true)
        }
        guard (200..<300).contains(status) else { throw IBKRError.http(status, String(decoding: data, as: UTF8.self)) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func requestLiveSessionToken() async throws {
        let url = Self.baseURL + "oauth/live_session_token"
        let dhRandom = BigUInt(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = dhGenerator.power(dhRandom, modulus: dhPrime)
        guard let secret = Data(base64Encoded: credentials.accessTokenSecret) else {
            throw IBKRError.badResponse("access token secret is not base64")
        }
        let prependBytes = try RSA.decryptPKCS1(secret, with: encryptionKey)
        let prepend = prependBytes.hex

        var params = oauthParams(signatureMethod: "RSA-SHA256")
        params["diffie_hellman_challenge"] = String(challenge, radix: 16)
        let base = baseString(method: "POST", url: url, params: params, prepend: prepend)
        params["oauth_signature"] = try RSA.signSHA256(Data(base.utf8), with: signatureKey).base64EncodedString().quotedPlus

        let (data, status) = try await send(method: "POST", url: url, params: params, body: nil)
        guard (200..<300).contains(status) else { throw IBKRError.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseHex = json["diffie_hellman_response"] as? String,
              let dhResponse = BigUInt(responseHex, radix: 16),
              let signature = json["live_session_token_signature"] as? String,
              let expiresMs = json["live_session_token_expiration"] as? Double
        else { throw IBKRError.badResponse(String(decoding: data, as: UTF8.self)) }

        let shared = dhResponse.power(dhRandom, modulus: dhPrime)
        let token = Data(HMAC<Insecure.SHA1>.authenticationCode(for: prependBytes, using: SymmetricKey(data: DH.signedBytes(shared))))
        let check = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(credentials.consumerKey.utf8), using: SymmetricKey(data: token))).hex
        guard check == signature else { throw IBKRError.sessionTokenMismatch }
        liveSessionToken = token
        // refresh a little early rather than hitting an expired token
        liveSessionExpires = Date(timeIntervalSince1970: expiresMs / 1000).addingTimeInterval(-300)
    }

    private func oauthParams(signatureMethod: String) -> [String: String] {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return [
            "oauth_consumer_key": credentials.consumerKey,
            "oauth_nonce": String((0..<16).map { _ in alphabet.randomElement()! }),
            "oauth_signature_method": signatureMethod,
            "oauth_timestamp": String(Int(Date.now.timeIntervalSince1970)),
            "oauth_token": credentials.accessToken,
        ]
    }

    private func baseString(method: String, url: String, params: [String: String], prepend: String?) -> String {
        let joined = params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined(separator: "&")
        return (prepend ?? "") + [method, url.quotedPlus, joined.quotedPlus].joined(separator: "&")
    }

    private func send(method: String, url: String, params: [String: String], body: Any?) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        let header = params.keys.sorted().map { "\($0)=\"\(params[$0]!)\"" }.joined(separator: ", ")
        req.setValue("OAuth realm=\"\(Self.realm)\", \(header)", forHTTPHeaderField: "Authorization")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("ibkr-widget", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
