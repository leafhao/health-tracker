import CryptoKit
import Foundation
import HealthKit

// MARK: - Canonical event model

enum HealthEntityType: String, Codable, Sendable {
    case quantity
    case category
    case workout
    case workoutRoute = "workout_route"
    case activitySummary = "activity_summary"
    case deviceCapabilities = "device_capabilities"
}

enum HealthEventOperation: String, Codable, Sendable {
    case upsert
    case delete
}

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

struct HealthEvent: Codable, Sendable {
    let eventID: String
    let operation: HealthEventOperation
    let entityType: HealthEntityType
    let sourceUUID: String
    let observedAt: String
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case operation
        case entityType = "entity_type"
        case sourceUUID = "source_uuid"
        case observedAt = "observed_at"
        case payload
    }

    static func upsert<T: Encodable>(
        entityType: HealthEntityType,
        sourceUUID: String,
        observedAt: Date,
        payload: T
    ) throws -> HealthEvent {
        let value = try JSONValue.encode(payload)
        return HealthEvent(
            eventID: try stableID(operation: .upsert, entityType: entityType, sourceUUID: sourceUUID, payload: value),
            operation: .upsert,
            entityType: entityType,
            sourceUUID: sourceUUID,
            observedAt: ISO8601DateFormatter.incrementalHealth.string(from: observedAt),
            payload: value
        )
    }

    static func delete(
        entityType: HealthEntityType,
        sourceUUID: String,
        observedAt: Date = Date()
    ) -> HealthEvent {
        HealthEvent(
            eventID: stableID(operation: .delete, entityType: entityType, sourceUUID: sourceUUID, payloadData: Data()),
            operation: .delete,
            entityType: entityType,
            sourceUUID: sourceUUID,
            observedAt: ISO8601DateFormatter.incrementalHealth.string(from: observedAt),
            payload: nil
        )
    }

    private static func stableID(
        operation: HealthEventOperation,
        entityType: HealthEntityType,
        sourceUUID: String,
        payload: JSONValue
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return stableID(
            operation: operation,
            entityType: entityType,
            sourceUUID: sourceUUID,
            payloadData: try encoder.encode(payload)
        )
    }

    private static func stableID(
        operation: HealthEventOperation,
        entityType: HealthEntityType,
        sourceUUID: String,
        payloadData: Data
    ) -> String {
        var material = Data("\(operation.rawValue)\0\(entityType.rawValue)\0\(sourceUUID)\0".utf8)
        material.append(payloadData)
        return "event-" + SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

struct HealthEventBatch: Codable, Sendable {
    let schemaVersion = 1
    let batchID: String
    let previousBatchID: String?
    let ownerID: String
    let deviceID: String
    let streamID: String
    let sequence: UInt64
    let createdAt: String
    let anchorDigest: String?
    let events: [HealthEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case batchID = "batch_id"
        case previousBatchID = "previous_batch_id"
        case ownerID = "owner_id"
        case deviceID = "device_id"
        case streamID = "stream_id"
        case sequence
        case createdAt = "created_at"
        case anchorDigest = "anchor_digest"
        case events
    }
}

// MARK: - HealthKit anchors

struct AnchoredHealthChanges: @unchecked Sendable {
    let added: [HKSample]
    let deleted: [HKDeletedObject]
    let newAnchor: HKQueryAnchor?
}

final class HealthAnchoredQueryService: @unchecked Sendable {
    private let store: HKHealthStore

    init(store: HKHealthStore = HealthKitService.shared.store) {
        self.store = store
    }

    func fetchAllChanges(
        for type: HKSampleType,
        anchor: HKQueryAnchor?,
        pageSize: Int = 500
    ) async throws -> AnchoredHealthChanges {
        precondition(pageSize > 0)
        var currentAnchor = anchor
        var added: [HKSample] = []
        var deleted: [HKDeletedObject] = []

        for _ in 0..<1_000 {
            let page = try await fetchChangesPage(for: type, anchor: currentAnchor, limit: pageSize)
            added.append(contentsOf: page.added)
            deleted.append(contentsOf: page.deleted)
            currentAnchor = page.newAnchor
            if page.added.count + page.deleted.count < pageSize {
                return AnchoredHealthChanges(added: added, deleted: deleted, newAnchor: currentAnchor)
            }
        }
        throw IncrementalSyncError.tooManyAnchorPages(type.identifier)
    }

    func fetchChangesPage(
        for type: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> AnchoredHealthChanges {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: AnchoredHealthChanges(
                        added: samples ?? [],
                        deleted: deleted ?? [],
                        newAnchor: newAnchor
                    ))
                }
            }
            store.execute(query)
        }
    }
}

actor HealthAnchorStore {
    private let directory: URL

    init(baseDirectory: URL? = nil) {
        let support = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = support.appending(path: "PersonalHealthSync/V2/Anchors", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load(streamID: String) throws -> HKQueryAnchor? {
        let target = url(for: streamID)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func persistedAnchorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "anchor" }.count
    }

    func archive(_ anchor: HKQueryAnchor?) throws -> Data? {
        guard let anchor else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    func commit(archivedAnchor: Data?, streamID: String) throws {
        guard let archivedAnchor else { return }
        try archivedAnchor.write(to: url(for: streamID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func url(for streamID: String) -> URL {
        let digest = SHA256.hash(data: Data(streamID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).anchor")
    }
}

// MARK: - Encrypted durable outbox

struct HealthPairingMaterial: Codable, Sendable {
    let ownerID: String
    let deviceID: String
    let receiverKeyID: String
    let receiverPublicKey: Data
    let signingKeyID: String

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case deviceID = "device_id"
        case receiverKeyID = "receiver_key_id"
        case receiverPublicKey = "receiver_public_key"
        case signingKeyID = "signing_key_id"
    }
}

private struct OutboxState: Codable {
    var nextSequence: UInt64 = 1
    var lastBatchID: String?
}

struct PendingEncryptedBatch: Sendable {
    let url: URL
    let sequence: UInt64
    let batchID: String
    let relayGroup: String?
}

struct RelayPackPartition: Sendable {
    let relayGroup: String?
    let partNumber: Int
    let partCount: Int
    let batches: [PendingEncryptedBatch]
}

enum RelayPackingPolicy {
    static let targetBytes = 8 * 1024 * 1024
    static let maximumBatches = 64

    static func partitions(_ batches: [PendingEncryptedBatch]) throws -> [RelayPackPartition] {
        var output: [RelayPackPartition] = []
        var segmentStart = batches.startIndex
        while segmentStart < batches.endIndex {
            let relayGroup = batches[segmentStart].relayGroup
            var segmentEnd = batches.index(after: segmentStart)
            while segmentEnd < batches.endIndex,
                  batches[segmentEnd].relayGroup == relayGroup {
                segmentEnd = batches.index(after: segmentEnd)
            }

            var rawParts: [[PendingEncryptedBatch]] = []
            var current: [PendingEncryptedBatch] = []
            var currentBytes = 0
            for batch in batches[segmentStart..<segmentEnd] {
                let values = try batch.url.resourceValues(forKeys: [.fileSizeKey])
                let size = values.fileSize ?? 0
                let wouldOverflow = !current.isEmpty && (
                    current.count >= maximumBatches || currentBytes + size > targetBytes
                )
                if wouldOverflow {
                    rawParts.append(current)
                    current = []
                    currentBytes = 0
                }
                current.append(batch)
                currentBytes += size
            }
            if !current.isEmpty { rawParts.append(current) }

            for (offset, part) in rawParts.enumerated() {
                output.append(RelayPackPartition(
                    relayGroup: relayGroup,
                    partNumber: offset + 1,
                    partCount: rawParts.count,
                    batches: part
                ))
            }
            segmentStart = segmentEnd
        }
        return output
    }
}

struct EncryptedOutboxCounts: Sendable {
    let awaitingUpload: Int
    let awaitingReceiver: Int
    let awaitingUploadPacks: Int

    var total: Int { awaitingUpload + awaitingReceiver }
}

struct InitialDirectProgressSnapshot: Sendable {
    let totalBatches: Int
    let completedBatches: Int
    let remainingBatches: Int
    let remainingPacks: Int
}

private struct CloudUploadMarker: Codable {
    let provider: String
    let objectKey: String
    let uploadedAt: Date
}

private struct RelayBatchMetadata: Codable {
    let relayGroup: String
}

@available(iOS 17.0, *)
actor EncryptedHealthOutbox {
    private let directory: URL
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let anchorStore: HealthAnchorStore

    init(baseDirectory: URL? = nil, anchorStore: HealthAnchorStore) {
        let support = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = support.appending(path: "PersonalHealthSync/V2/Outbox", directoryHint: .isDirectory)
        stateURL = directory.appending(path: "state.json")
        self.anchorStore = anchorStore
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func enqueue(
        streamID: String,
        events: [HealthEvent],
        newAnchor: HKQueryAnchor?,
        pairing: HealthPairingMaterial,
        deviceSigningPrivateKey: Data,
        relayGroup: String? = nil
    ) async throws -> PendingEncryptedBatch? {
        let archivedAnchor = try await anchorStore.archive(newAnchor)
        guard !events.isEmpty else {
            try await anchorStore.commit(archivedAnchor: archivedAnchor, streamID: streamID)
            return nil
        }

        var state = try loadState()
        let sequence = state.nextSequence
        state.nextSequence += 1
        try saveState(state) // Reserve first: a crash may create a visible gap, never sequence reuse.

        let batchID = UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter.incrementalHealth.string(from: Date())
        let batch = HealthEventBatch(
            batchID: batchID,
            previousBatchID: state.lastBatchID,
            ownerID: pairing.ownerID,
            deviceID: pairing.deviceID,
            streamID: streamID,
            sequence: sequence,
            createdAt: createdAt,
            anchorDigest: archivedAnchor.map(Self.digest),
            events: events
        )
        let payload = try encoder.encode(batch)
        let paddingSize = (4_096 - payload.count % 4_096) % 4_096
        let header = HealthSyncEnvelopeHeader(
            protocol: "health-envelope/1",
            batchID: batchID,
            deviceID: pairing.deviceID,
            sequence: sequence,
            receiverKeyID: pairing.receiverKeyID,
            signingKeyID: pairing.signingKeyID,
            createdAt: createdAt,
            contentType: "application/vnd.health-event-batch+json;v=1",
            contentEncoding: "identity",
            plaintextSize: payload.count,
            paddingSize: paddingSize
        )
        let envelope = try HealthSyncEnvelopeSealer.seal(
            payload: payload,
            header: header,
            receiverPublicKey: pairing.receiverPublicKey,
            deviceSigningPrivateKey: deviceSigningPrivateKey
        )
        let target = directory.appending(path: String(format: "%020llu-%@.henv", sequence, batchID))
        try encoder.encode(envelope).write(
            to: target,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        if let relayGroup {
            try encoder.encode(RelayBatchMetadata(relayGroup: relayGroup)).write(
                to: relayMetadataURL(for: target),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
        state.lastBatchID = batchID
        try saveState(state)
        try await anchorStore.commit(archivedAnchor: archivedAnchor, streamID: streamID)
        return PendingEncryptedBatch(
            url: target,
            sequence: sequence,
            batchID: batchID,
            relayGroup: relayGroup
        )
    }

    func pending() throws -> [PendingEncryptedBatch] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "henv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let sequence = UInt64(parts[0]) else { return nil }
            let metadata = try? decoder.decode(
                RelayBatchMetadata.self,
                from: Data(contentsOf: relayMetadataURL(for: url))
            )
            return PendingEncryptedBatch(
                url: url,
                sequence: sequence,
                batchID: String(parts[1]),
                relayGroup: metadata?.relayGroup
            )
        }
    }

    func counts(provider: CloudStorageProvider) throws -> EncryptedOutboxCounts {
        let batches = try pending()
        let uploaded = batches.filter { batch in
            guard let marker = try? loadMarker(for: batch) else { return false }
            return marker.provider == provider.rawValue
        }.count
        let awaiting = batches.filter { batch in
            guard let marker = try? loadMarker(for: batch) else { return true }
            return marker.provider != provider.rawValue
        }
        return EncryptedOutboxCounts(
            awaitingUpload: batches.count - uploaded,
            awaitingReceiver: uploaded,
            awaitingUploadPacks: try RelayPackingPolicy.partitions(awaiting).count
        )
    }

    func initialDirectProgressSnapshot() throws -> InitialDirectProgressSnapshot {
        let batches = try pending()
        let total = Int((try loadState()).nextSequence - 1)
        let completed = max(0, total - batches.count)
        return InitialDirectProgressSnapshot(
            totalBatches: total,
            completedBatches: completed,
            remainingBatches: batches.count,
            remainingPacks: try RelayPackingPolicy.partitions(batches).count
        )
    }

    func uploadMarker(for batch: PendingEncryptedBatch) throws -> (provider: String, objectKey: String, uploadedAt: Date)? {
        guard let marker = try loadMarker(for: batch) else { return nil }
        return (marker.provider, marker.objectKey, marker.uploadedAt)
    }

    func uploadedObjectKeys(provider: CloudStorageProvider) throws -> [String] {
        var seen = Set<String>()
        return try pending().compactMap { batch in
            guard let marker = try loadMarker(for: batch),
                  marker.provider == provider.rawValue,
                  seen.insert(marker.objectKey).inserted else { return nil }
            return marker.objectKey
        }
    }

    func markUploaded(
        _ batch: PendingEncryptedBatch,
        provider: CloudStorageProvider,
        objectKey: String
    ) throws {
        let marker = CloudUploadMarker(
            provider: provider.rawValue,
            objectKey: objectKey,
            uploadedAt: Date()
        )
        try encoder.encode(marker).write(
            to: markerURL(for: batch),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func remove(_ batch: PendingEncryptedBatch) throws {
        if FileManager.default.fileExists(atPath: batch.url.path) {
            try FileManager.default.removeItem(at: batch.url)
        }
        let marker = markerURL(for: batch)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
        let relayMetadata = relayMetadataURL(for: batch.url)
        if FileManager.default.fileExists(atPath: relayMetadata.path) {
            try FileManager.default.removeItem(at: relayMetadata)
        }
    }

    func confirmUploaded(objectKey: String, batchIDs: Set<String>) throws -> Int {
        var confirmed = 0
        for batch in try pending() where batchIDs.contains(batch.batchID) {
            guard let marker = try loadMarker(for: batch), marker.objectKey == objectKey else {
                continue
            }
            try remove(batch)
            confirmed += 1
        }
        return confirmed
    }

    private func loadState() throws -> OutboxState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return OutboxState() }
        return try decoder.decode(OutboxState.self, from: Data(contentsOf: stateURL))
    }

    private func saveState(_ state: OutboxState) throws {
        try encoder.encode(state).write(
            to: stateURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func markerURL(for batch: PendingEncryptedBatch) -> URL {
        batch.url.appendingPathExtension("uploaded.json")
    }

    private func relayMetadataURL(for envelopeURL: URL) -> URL {
        envelopeURL.appendingPathExtension("relay.json")
    }

    private func loadMarker(for batch: PendingEncryptedBatch) throws -> CloudUploadMarker? {
        let target = markerURL(for: batch)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try decoder.decode(CloudUploadMarker.self, from: Data(contentsOf: target))
    }

    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

enum IncrementalSyncError: Error, LocalizedError {
    case tooManyAnchorPages(String)

    var errorDescription: String? {
        switch self {
        case .tooManyAnchorPages(let stream):
            return "HealthKit stream produced too many pages without reaching its current anchor: \(stream)"
        }
    }
}

extension ISO8601DateFormatter {
    static let incrementalHealth: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
