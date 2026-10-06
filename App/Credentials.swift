import Foundation
import Security

/// IBKR OAuth 1.0a credentials. Stored as one item in the login Keychain, readable only by this app.
struct Credentials: Codable, Equatable {
    var consumerKey = ""
    var accessToken = ""
    var accessTokenSecret = ""
    var signatureKeyPEM = ""
    var encryptionKeyPEM = ""
    var dhParamsPEM = ""

    var isComplete: Bool {
        ![consumerKey, accessToken, accessTokenSecret, signatureKeyPEM, encryptionKeyPEM, dhParamsPEM].contains { $0.isEmpty }
    }

    // MARK: Keychain
    //
    // Preferred: the data-protection keychain, where the item is bound to this app's identity and no other
    // process can read it or even prompt for it. If the signing setup does not allow that, fall back to the
    // legacy login keychain (other apps can request the item, which shows the user an "Allow" prompt).

    private static let service = "com.ou.ibkrwidget.oauth"

    /// The live item; the Connect assistant keeps a second, pending set until a token is captured.
    static let liveAccount = "ibkr"
    static let pendingAccount = "ibkr-pending"

    private static func query(dataProtection: Bool, account: String = liveAccount) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if dataProtection { q[kSecUseDataProtectionKeychain] = true }
        return q
    }

    private static func read(dataProtection: Bool, account: String = liveAccount) -> Credentials? {
        var q = query(dataProtection: dataProtection, account: account)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private func write(dataProtection: Bool, account: String = Self.liveAccount) throws {
        let data = try JSONEncoder().encode(self)
        let q = Self.query(dataProtection: dataProtection, account: account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
    }

    static func load() -> Credentials? {
        if let c = read(dataProtection: true) { return c }
        guard let legacy = read(dataProtection: false) else { return nil }
        // migrate an item saved by an earlier build into the data-protection keychain when possible
        if (try? legacy.write(dataProtection: true)) != nil {
            SecItemDelete(query(dataProtection: false) as CFDictionary)
        }
        return legacy
    }

    func save() throws {
        do {
            try write(dataProtection: true)
            SecItemDelete(Self.query(dataProtection: false) as CFDictionary)
        } catch {
            try write(dataProtection: false)
        }
    }

    static func delete() {
        SecItemDelete(query(dataProtection: true) as CFDictionary)
        SecItemDelete(query(dataProtection: false) as CFDictionary)
    }

    // MARK: pending set (Connect assistant)

    static func loadPending() -> Credentials? {
        read(dataProtection: true, account: pendingAccount) ?? read(dataProtection: false, account: pendingAccount)
    }

    func savePending() throws {
        do { try write(dataProtection: true, account: Self.pendingAccount) } catch { try write(dataProtection: false, account: Self.pendingAccount) }
    }

    static func deletePending() {
        SecItemDelete(query(dataProtection: true, account: pendingAccount) as CFDictionary)
        SecItemDelete(query(dataProtection: false, account: pendingAccount) as CFDictionary)
    }

    // MARK: import from an ~/.ibkr-style folder

    /// Reads `ibkr_env_<env>` ("key: value" lines) and the key files it references from `folder`.
    static func importFolder(_ folder: URL, env: String = "live") throws -> Credentials {
        let envFile = folder.appendingPathComponent("ibkr_env_\(env)")
        let text = try String(contentsOf: envFile, encoding: .utf8)
        var kv: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: ":") else { continue }
            kv[line[..<i].trimmingCharacters(in: .whitespaces)] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        func file(_ key: String) throws -> String {
            guard let path = kv[key] else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(key) missing in \(envFile.lastPathComponent)"]) }
            // the env file holds absolute paths; resolve by name inside the chosen folder so the sandbox grant covers it
            let local = folder.appendingPathComponent((path as NSString).lastPathComponent)
            return try String(contentsOf: FileManager.default.fileExists(atPath: local.path) ? local : URL(fileURLWithPath: path), encoding: .utf8)
        }
        return Credentials(
            consumerKey: kv["consumer_key"] ?? "",
            accessToken: kv["access_token"] ?? "",
            accessTokenSecret: kv["access_secret"] ?? "",
            signatureKeyPEM: try file("signature_key"),
            encryptionKeyPEM: try file("encryption_key"),
            dhParamsPEM: try file("dh_prime")
        )
    }
}
