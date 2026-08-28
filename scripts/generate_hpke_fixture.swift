import CryptoKit
import Foundation

@main
struct GenerateHPKEFixture {
    static func main() throws {
        let receiverPrivateData = Data((1...32).map(UInt8.init))
        let signingPrivateData = Data((33...64).map(UInt8.init))
        let receiverPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: receiverPrivateData
        )
        let signingPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: signingPrivateData
        )
        let payloadObject: [String: Any] = [
            "batch_id": "0198d8e0-swift-fixture",
            "created_at": "2026-08-28T14:00:00.000Z",
            "device_id": "device-fixture",
            "events": [[
                "entity_type": "quantity",
                "event_id": "event-fixture-0001",
                "observed_at": "2026-08-28T13:59:00.000Z",
                "operation": "upsert",
                "payload": ["unit": "count/min", "value": 72.0] as [String: Any],
                "source_uuid": "sample-fixture-uuid",
            ]],
            "owner_id": "owner-fixture",
            "schema_version": 1,
            "sequence": 42,
            "stream_id": "HKQuantityTypeIdentifierHeartRate",
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let header = HealthSyncEnvelopeHeader(
            protocol: "health-envelope/1",
            batchID: "0198d8e0-swift-fixture",
            deviceID: "device-fixture",
            sequence: 42,
            receiverKeyID: "receiver-fixture",
            signingKeyID: "iphone-fixture",
            createdAt: "2026-08-28T14:00:00.000Z",
            contentType: "application/vnd.health-event-batch+json;v=1",
            contentEncoding: "identity",
            plaintextSize: payload.count,
            paddingSize: 16
        )
        let envelope = try HealthSyncEnvelopeSealer.seal(
            payload: payload,
            header: header,
            receiverPublicKey: receiverPrivateKey.publicKey.rawRepresentation,
            deviceSigningPrivateKey: signingPrivateData
        )
        let envelopeData = try JSONEncoder.sorted.encode(envelope)
        let envelopeObject = try JSONSerialization.jsonObject(with: envelopeData)
        let fixture: [String: Any] = [
            "device_signing_public_key_base64": signingPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            "envelope": envelopeObject,
            "expected_payload": payloadObject,
            "receiver_private_key_base64": receiverPrivateData.base64EncodedString(),
        ]
        let output = try JSONSerialization.data(
            withJSONObject: fixture,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
