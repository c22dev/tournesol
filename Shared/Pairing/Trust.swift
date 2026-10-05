//
//  Trust.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import CryptoKit
import Foundation
import Security

nonisolated struct TrustedPeer: Codable, Hashable, Sendable {
    var publicKey: Data
    var name: String
    var kind: DeviceKind
}

@Observable
final class SecurityContext {
    private(set) var trusted: [String: TrustedPeer]
    @ObservationIgnored let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    init() {
        if let raw = Keychain.data(for: "identity"), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            privateKey = key
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            Keychain.set(privateKey.rawRepresentation, for: "identity")
        }
        trusted = Keychain.data(for: "trusted").flatMap { try? JSONDecoder().decode([String: TrustedPeer].self, from: $0) } ?? [:]
    }

    func isTrusted(_ hello: Hello) -> Bool {
        trusted[hello.info.id]?.publicKey == hello.publicKey
    }

    func trust(_ hello: Hello) {
        trusted[hello.info.id] = TrustedPeer(publicKey: hello.publicKey, name: hello.info.name, kind: hello.info.kind)
        save()
    }

    func forget(_ id: String) {
        trusted[id] = nil
        save()
    }

    func sessionKey(with hello: Hello, localNonce: Data) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.publicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        let salt = [localNonce, hello.nonce].sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("tournesol.session.v1".utf8), outputByteCount: 32)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(trusted) else { return }
        Keychain.set(data, for: "trusted")
    }
}

nonisolated enum SecureBox {
    static func seal(_ message: Message, sequence: UInt64, senderNonce: Data, key: SymmetricKey) -> Data? {
        guard let plaintext = try? MessageCodec.encode(message) else { return nil }
        return try? ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData(senderNonce, sequence)).combined
    }

    static func open(_ box: Data, sequence: UInt64, senderNonce: Data, key: SymmetricKey) -> Message? {
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box),
              let plaintext = try? ChaChaPoly.open(sealed, using: key, authenticating: associatedData(senderNonce, sequence))
        else { return nil }
        return try? MessageCodec.decode(Message.self, from: plaintext)
    }

    private static func associatedData(_ nonce: Data, _ sequence: UInt64) -> Data {
        var data = nonce
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        return data
    }
}

nonisolated enum PairingMath {
    static func nonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func commitment(responderKey: Data, initiatorKey: Data, responderNonce: Data) -> Data {
        Data(SHA256.hash(data: Data("commit".utf8) + responderKey + initiatorKey + responderNonce))
    }

    static func code(initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("code".utf8) + initiatorKey + responderKey + initiatorNonce + responderNonce))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

nonisolated enum Keychain {
    private static let service = "ch.cclerc.Tournesol"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) {
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = query
        item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
