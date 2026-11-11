import CryptoKit
import Foundation

/// This Mac's anonymous fax identity: one Ed25519 key pair (protocol §1).
struct DeviceIdentity: Sendable {
    /// The 32-byte private key seed.
    let privateKeyRaw: Data
    let publicKeyRaw: Data
    /// base64url(SHA-256(public key)), first 22 characters. Matches the server's value.
    let deviceId: String

    init(privateKeyRaw: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        self.privateKeyRaw = privateKeyRaw
        publicKeyRaw = key.publicKey.rawRepresentation
        deviceId = Self.deviceId(forPublicKey: publicKeyRaw)
    }

    static func generate() -> DeviceIdentity {
        let raw = Curve25519.Signing.PrivateKey().rawRepresentation
        // A freshly generated key always round-trips.
        return try! DeviceIdentity(privateKeyRaw: raw)
    }

    static func deviceId(forPublicKey publicKey: Data) -> String {
        String(Base64URL.encode(Data(SHA256.hash(data: publicKey))).prefix(22))
    }

    /// The UTF-8 string that is signed to open a session.
    static func sessionMessage(timestamp: Int64) -> String {
        "notchfax-session:\(timestamp)"
    }

    /// The body of `POST /v1/session`.
    func sessionRequest(timestamp: Int64) throws -> SessionRequest {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        let signature = try key.signature(for: Data(Self.sessionMessage(timestamp: timestamp).utf8))
        return SessionRequest(
            publicKey: Base64URL.encode(publicKeyRaw),
            timestamp: timestamp,
            signature: Base64URL.encode(signature)
        )
    }
}

/// RFC 4648 §5 without padding, as the server expects.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
