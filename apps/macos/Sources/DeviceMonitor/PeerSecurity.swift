import CryptoKit
import Foundation
import Security

enum PeerSecurity {
    static let timestampWindowMilliseconds: Int64 = 120_000

    static func generateSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PeerProtocolError.invalidSecret
        }
        return Data(bytes)
    }

    static func generateNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PeerProtocolError.invalidRequest
        }
        return Data(bytes).base64URLEncodedString
    }

    static func decodeSecret(_ value: String) throws -> Data {
        guard let data = Data(base64URLString: value.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
            throw PeerProtocolError.invalidSecret
        }
        return data
    }

    static func bodyHash(_ body: Data) -> String {
        Data(SHA256.hash(data: body)).lowercaseHex
    }

    static func requestCanonical(timestamp: Int64, nonce: String, body: Data = Data()) -> String {
        "GET\n/v1/status\n\(timestamp)\n\(nonce)\n\(bodyHash(body))"
    }

    static func responseCanonical(status: Int, timestamp: Int64, nonce: String, body: Data) -> String {
        "\(status)\n/v1/status\n\(timestamp)\n\(nonce)\n\(bodyHash(body))"
    }

    static func signature(canonical: String, secret: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: secret)
        )
        return Data(code).lowercaseHex
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

extension Data {
    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: value)
    }

    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}

enum PeerSecretStore {
    private static let service = "com.yangyuchen.devicemonitor.peer"
    private static let legacyService = "com.yangyuchen.macmonitor.peer"
    private static let account = "pairing-secret-v1"

    static func load() -> String? {
        if let value = load(service: service) { return value }
        guard let legacyValue = load(service: legacyService) else { return nil }
        try? save(legacyValue)
        return legacyValue
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func save(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = Data(value.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw PeerProtocolError.invalidSecret
            }
        } else if status != errSecSuccess {
            throw PeerProtocolError.invalidSecret
        }
    }
}
