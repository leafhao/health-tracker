import CryptoKit
import Foundation

struct HealthSyncEnvelopeHeader: Codable, Sendable {
    let `protocol`: String
    let batchID: String
    let deviceID: String
    let sequence: UInt64
    let receiverKeyID: String
    let signingKeyID: String
    let createdAt: String
    let contentType: String
    let contentEncoding: String
    let plaintextSize: Int
    let paddingSize: Int

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case batchID = "batch_id"
        case deviceID = "device_id"
        case sequence
        case receiverKeyID = "receiver_key_id"
        case signingKeyID = "signing_key_id"
        case createdAt = "created_at"
        case contentType = "content_type"
        case contentEncoding = "content_encoding"
        case plaintextSize = "plaintext_size"
        case paddingSize = "padding_size"
    }
}

struct HealthSyncEnvelope: Codable, Sendable {
    let format: String
    let headerBase64: String
    let hpkeCiphertextBase64: String
    let signatureBase64: String

    enum CodingKeys: String, CodingKey {
        case format
        case headerBase64 = "header_base64"
        case hpkeCiphertextBase64 = "hpke_ciphertext_base64"
        case signatureBase64 = "signature_base64"
    }
}

enum HealthSyncEnvelopeError: Error {
    case unsupportedEncoding
    case plaintextSizeMismatch
}

@available(iOS 17.0, *)
enum HealthSyncEnvelopeSealer {
    private static let signaturePrefix = Data("HEALTH-ENVELOPE-V1\0".utf8)
    private static let infoPrefix = Data("health-envelope-v1\0".utf8)

    static func seal(
        payload: Data,
        header: HealthSyncEnvelopeHeader,
        receiverPublicKey: Data,
        deviceSigningPrivateKey: Data
    ) throws -> HealthSyncEnvelope {
        guard header.contentEncoding == "identity" else {
            throw HealthSyncEnvelopeError.unsupportedEncoding
        }
        guard header.plaintextSize == payload.count else {
            throw HealthSyncEnvelopeError.plaintextSizeMismatch
        }
        var padded = payload
        if header.paddingSize > 0 {
            padded.append(Data(repeating: 0, count: header.paddingSize))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let headerData = try encoder.encode(header)
        let headerDigest = Data(SHA256.hash(data: headerData))
        let info = infoPrefix + headerDigest
        let receiverKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: receiverPublicKey
        )
        var sender = try HPKE.Sender(
            recipientKey: receiverKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        let ciphertext = try sender.seal(padded)
        let hpkeCiphertext = sender.encapsulatedKey + ciphertext
        let signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: deviceSigningPrivateKey
        )
        let signature = try signingKey.signature(
            for: signaturePrefix + headerData + hpkeCiphertext
        )
        return HealthSyncEnvelope(
            format: "health-envelope/1",
            headerBase64: headerData.base64EncodedString(),
            hpkeCiphertextBase64: hpkeCiphertext.base64EncodedString(),
            signatureBase64: signature.base64EncodedString()
        )
    }
}
