import CryptoKit
import Foundation

struct CloudRelayUploadResult: Sendable {
    let uploaded: Int
    let awaitingReceiver: Int
    let deferredUntil: Date?
}

struct CloudRelayHandoffResult: Sendable {
    let uploadedImmediately: Int
    let scheduledInBackground: Int
    let deferredUntil: Date?
}

private struct CloudRelayReceipt: Decodable {
    let `protocol`: String
    let deviceID: String
    let objectKey: String
    let packID: String
    let committedAt: String
    let batchIDs: [String]
    let hmacSHA256: String

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case deviceID = "device_id"
        case objectKey = "object_key"
        case packID = "pack_id"
        case committedAt = "committed_at"
        case batchIDs = "batch_ids"
        case hmacSHA256 = "hmac_sha256"
    }
}

struct HealthRelayPack: Encodable {
    let `protocol`: String
    let packID: String
    let deviceID: String
    let createdAt: String
    let firstSequence: UInt64
    let lastSequence: UInt64
    let groupID: String
    let partNumber: Int
    let partCount: Int
    let envelopes: [HealthSyncEnvelope]

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case packID = "pack_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
        case groupID = "group_id"
        case partNumber = "part_number"
        case partCount = "part_count"
        case envelopes
    }
}

struct PreparedRelayPack {
    let id: String
    let groupID: String
    let batches: [PendingEncryptedBatch]
    let partNumber: Int
    let partCount: Int

    var firstSequence: UInt64 { batches.first?.sequence ?? 0 }
    var lastSequence: UInt64 { batches.last?.sequence ?? 0 }
}

actor CloudRelayTransport {
    private let session: URLSession
    private let backgroundTransfers = BackgroundHTTPTransferCenter.shared
    private var nextRequestNotBefore = Date.distantPast
    private var rateLimitedUntil: Date?
    private var consecutiveRateLimits = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func test(config: CloudStorageConfig, credentials: CloudStorageCredentials) async throws -> String {
        try validate(config: config, credentials: credentials)
        switch config.provider {
        case .s3:
            try await testS3(config: config, credentials: credentials)
            return "S3 Bucket 连接成功"
        case .webDAV:
            guard let url = config.normalizedEndpoint else { throw CloudStorageError.invalidConfiguration }
            var request = URLRequest(url: url)
            request.httpMethod = "PROPFIND"
            request.httpBody = Data("<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>".utf8)
            request.setValue("0", forHTTPHeaderField: "Depth")
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.basic(credentials), forHTTPHeaderField: "Authorization")
            _ = try await perform(request, accepted: [200, 207])
            return "WebDAV 连接成功"
        case .directDebug:
            guard let url = config.normalizedEndpoint else { throw CloudStorageError.invalidConfiguration }
            let health = url.appending(path: "api/v1/healthbeat/health")
            var request = URLRequest(url: health)
            request.httpMethod = "GET"
            _ = try await perform(request, accepted: [200])
            return "调试接收器连接成功"
        }
    }

    func uploadPending(
        outbox: EncryptedHealthOutbox,
        pairing: HealthPairingMaterial,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) async throws -> CloudRelayUploadResult {
        try validate(config: config, credentials: credentials)
        guard config.provider != .directDebug else {
            throw CloudStorageError.signing("direct debug uses DirectEncryptedBatchUploader")
        }
        if config.provider == .s3 {
            _ = try await reconcileReceipts(
                outbox: outbox,
                pairing: pairing,
                config: config,
                credentials: credentials
            )
        }
        var candidates: [PendingEncryptedBatch] = []
        for batch in try await outbox.pending() {
            if let marker = try await outbox.uploadMarker(for: batch),
               marker.provider == config.provider.rawValue {
                continue
            }
            candidates.append(batch)
        }

        let packs = try Self.preparePacks(candidates: candidates, stableIDs: true)
        var uploaded = 0
        for pack in packs {
            // Only one bounded Part is materialized at a time. A large historical
            // outbox therefore does not become a multi-gigabyte in-memory array.
            let body = try Self.encode(pack: pack, pairing: pairing)
            let objectKey = Self.objectKey(config: config, pairing: pairing, pack: pack)
            do {
                switch config.provider {
                case .s3:
                    let url = try S3RequestSigner.url(config: config, objectKey: objectKey)
                    var request = URLRequest(url: url)
                    request.httpMethod = "PUT"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    try S3RequestSigner.sign(
                        request: &request,
                        body: body,
                        config: config,
                        credentials: credentials
                    )
                    try await waitForRequestSlot(
                        minimumSpacing: config.usesCSTCloudCompatibility ? 1.25 : 0
                    )
                    let (responseBody, response) = try await backgroundTransfers.upload(
                        request: request,
                        body: body,
                        transferID: Self.backgroundTransferID(
                            config: config,
                            objectKey: objectKey,
                            pack: pack
                        )
                    )
                    try Self.validateUploadResponse(response, body: responseBody)
                case .webDAV:
                    try await ensureWebDAVCollections(
                        config: config,
                        credentials: credentials,
                        components: Self.objectDirectoryComponents(config: config, pairing: pairing)
                    )
                    guard let base = config.normalizedEndpoint else { throw CloudStorageError.invalidConfiguration }
                    let url = Self.appendingPath(objectKey, to: base)
                    var request = URLRequest(url: url)
                    request.httpMethod = "PUT"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(Self.basic(credentials), forHTTPHeaderField: "Authorization")
                    _ = try await perform(request, accepted: [200, 201, 204])
                case .directDebug:
                    break
                }
            } catch CloudStorageError.rateLimited(let retryAt) {
                let counts = try await outbox.counts(provider: config.provider)
                return CloudRelayUploadResult(
                    uploaded: uploaded,
                    awaitingReceiver: counts.awaitingReceiver,
                    deferredUntil: retryAt
                )
            }
            for batch in pack.batches {
                try await outbox.markUploaded(batch, provider: config.provider, objectKey: objectKey)
            }
            uploaded += pack.batches.count
        }
        let counts = try await outbox.counts(provider: config.provider)
        return CloudRelayUploadResult(
            uploaded: uploaded,
            awaitingReceiver: counts.awaitingReceiver,
            deferredUntil: nil
        )
    }

    /// Schedule one stable S3 pack with the system background URLSession and
    /// return as soon as iOS owns the file. Upload markers are written only when
    /// a later foreground/BG refresh consumes the persisted HTTP result.
    func schedulePending(
        outbox: EncryptedHealthOutbox,
        pairing: HealthPairingMaterial,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) async throws -> Int {
        try validate(config: config, credentials: credentials)
        guard config.provider == .s3 else { return 0 }
        var candidates: [PendingEncryptedBatch] = []
        for batch in try await outbox.pending() {
            if let marker = try await outbox.uploadMarker(for: batch),
               marker.provider == config.provider.rawValue {
                continue
            }
            candidates.append(batch)
        }
        guard let pack = try Self.preparePacks(
            candidates: candidates,
            stableIDs: true
        ).first else { return 0 }
        let body = try Self.encode(pack: pack, pairing: pairing)
        let objectKey = Self.objectKey(config: config, pairing: pairing, pack: pack)
        let url = try S3RequestSigner.url(config: config, objectKey: objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try S3RequestSigner.sign(
            request: &request,
            body: body,
            config: config,
            credentials: credentials
        )
        do {
            if let (responseBody, response) = try backgroundTransfers
                .consumeCompletedResult(transferID: Self.backgroundTransferID(
                    config: config,
                    objectKey: objectKey,
                    pack: pack
                )) {
                try Self.validateUploadResponse(response, body: responseBody)
                for batch in pack.batches {
                    try await outbox.markUploaded(
                        batch,
                        provider: config.provider,
                        objectKey: objectKey
                    )
                }
                return pack.batches.count
            }
        } catch let error as CloudStorageError {
            if case .rateLimited = error { throw error }
            // A completed transient failure is consumed and the same stable
            // pack is scheduled again below.
        } catch {
            // URLSession transport errors are retryable through the stable pack.
        }
        try await waitForRequestSlot(
            minimumSpacing: config.usesCSTCloudCompatibility ? 1.25 : 0
        )
        try await backgroundTransfers.schedule(
            request: request,
            body: body,
            transferID: Self.backgroundTransferID(
                config: config,
                objectKey: objectKey,
                pack: pack
            )
        )
        return pack.batches.count
    }

    /// During a real execution opportunity, first try one small stable pack
    /// immediately. If the network is slow or temporarily unavailable, hand
    /// the exact same signed PUT to iOS' background URLSession. This improves
    /// freshness without making correctness depend on foreground lifetime.
    func handoffPending(
        outbox: EncryptedHealthOutbox,
        pairing: HealthPairingMaterial,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        immediateByteLimit: Int = 1_000_000,
        allowImmediateUpload: Bool = true
    ) async throws -> CloudRelayHandoffResult {
        try validate(config: config, credentials: credentials)
        guard config.provider == .s3 else {
            let result = try await uploadPending(
                outbox: outbox,
                pairing: pairing,
                config: config,
                credentials: credentials
            )
            return CloudRelayHandoffResult(
                uploadedImmediately: result.uploaded,
                scheduledInBackground: 0,
                deferredUntil: result.deferredUntil
            )
        }

        var candidates: [PendingEncryptedBatch] = []
        for batch in try await outbox.pending() {
            if let marker = try await outbox.uploadMarker(for: batch),
               marker.provider == config.provider.rawValue {
                continue
            }
            candidates.append(batch)
        }
        guard let pack = try Self.preparePacks(candidates: candidates, stableIDs: true).first else {
            return CloudRelayHandoffResult(
                uploadedImmediately: 0,
                scheduledInBackground: 0,
                deferredUntil: nil
            )
        }

        let body = try Self.encode(pack: pack, pairing: pairing)
        let objectKey = Self.objectKey(config: config, pairing: pairing, pack: pack)
        let transferID = Self.backgroundTransferID(config: config, objectKey: objectKey, pack: pack)
        let url = try S3RequestSigner.url(config: config, objectKey: objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try S3RequestSigner.sign(
            request: &request,
            body: body,
            config: config,
            credentials: credentials
        )

        if let (completedBody, completedResponse) = try backgroundTransfers
            .consumeCompletedResult(transferID: transferID) {
            try Self.validateUploadResponse(completedResponse, body: completedBody)
            for batch in pack.batches {
                try await outbox.markUploaded(batch, provider: .s3, objectKey: objectKey)
            }
            return CloudRelayHandoffResult(
                uploadedImmediately: pack.batches.count,
                scheduledInBackground: 0,
                deferredUntil: nil
            )
        }

        if allowImmediateUpload, body.count <= immediateByteLimit {
            do {
                try await waitForRequestSlot(
                    minimumSpacing: config.usesCSTCloudCompatibility ? 1.25 : 0
                )
                let (responseBody, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudStorageError.invalidResponse
                }
                try Self.validateUploadResponse(http, body: responseBody)
                for batch in pack.batches {
                    try await outbox.markUploaded(batch, provider: .s3, objectKey: objectKey)
                }
                return CloudRelayHandoffResult(
                    uploadedImmediately: pack.batches.count,
                    scheduledInBackground: 0,
                    deferredUntil: nil
                )
            } catch CloudStorageError.rateLimited(let retryAt) {
                rateLimitedUntil = retryAt
                return CloudRelayHandoffResult(
                    uploadedImmediately: 0,
                    scheduledInBackground: 0,
                    deferredUntil: retryAt
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CloudStorageError {
                switch error {
                case .http(let status, _) where Self.isRetryable(status: status):
                    break
                case .invalidResponse:
                    break
                default:
                    throw error
                }
            } catch let error as URLError {
                guard Self.isRetryable(error: error) else { throw error }
            } catch {
                // A transport or 5xx failure falls through to the durable
                // background handoff below. Stable object keys make retries safe.
            }
        }

        try await backgroundTransfers.schedule(
            request: request,
            body: body,
            transferID: transferID
        )
        return CloudRelayHandoffResult(
            uploadedImmediately: 0,
            scheduledInBackground: pack.batches.count,
            deferredUntil: nil
        )
    }

    func reconcileReceipts(
        outbox: EncryptedHealthOutbox,
        pairing: HealthPairingMaterial,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        maximumReceipts: Int = 20
    ) async throws -> Int {
        try validate(config: config, credentials: credentials)
        guard config.provider == .s3 else { return 0 }
        return try await reconcileS3Receipts(
            outbox: outbox,
            pairing: pairing,
            config: config,
            credentials: credentials,
            maximumReceipts: maximumReceipts
        )
    }

    private func reconcileS3Receipts(
        outbox: EncryptedHealthOutbox,
        pairing: HealthPairingMaterial,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        maximumReceipts: Int
    ) async throws -> Int {
        let receiptDirectory = (config.prefix.split(separator: "/").map(String.init)
            + ["receipts", pairing.deviceID]).joined(separator: "/")
        // Receipt names are deterministic from the already-persisted upload
        // marker. Direct GET avoids ListObjects directory markers and removes
        // one rate-limited S3 request from every foreground/background run.
        let uploadedObjectKeys = try await outbox.uploadedObjectKeys(provider: .s3)
        let receiptKey = try await HealthV2PairingService.shared.receiptHMACKey()
        var confirmed = 0
        var processedReceipts = 0
        var firstError: Error?
        for objectKey in uploadedObjectKeys.prefix(max(1, maximumReceipts)) {
            do {
                let filename = String(objectKey.split(separator: "/").last ?? "")
                guard filename.hasSuffix(".hpack") else { continue }
                let packID = String(filename.dropLast(".hpack".count))
                let key = receiptDirectory + "/" + packID + ".json"
                let url = try S3RequestSigner.url(config: config, objectKey: key)
                var get = URLRequest(url: url)
                get.httpMethod = "GET"
                try S3RequestSigner.sign(
                    request: &get, body: Data(), config: config, credentials: credentials
                )
                let data = try await perform(
                    get,
                    accepted: [200],
                    minimumSpacing: config.usesCSTCloudCompatibility ? 1.25 : 0
                )
                let receipt = try JSONDecoder().decode(CloudRelayReceipt.self, from: data)
                guard receipt.protocol == "health-cloud-receipt/1",
                      receipt.deviceID == pairing.deviceID,
                      Self.validReceipt(receipt, key: receiptKey) else {
                    throw CloudStorageError.signing("Receiver 云端回执认证失败")
                }
                confirmed += try await outbox.confirmUploaded(
                    objectKey: receipt.objectKey,
                    batchIDs: Set(receipt.batchIDs)
                )
                var delete = URLRequest(url: url)
                delete.httpMethod = "DELETE"
                try S3RequestSigner.sign(
                    request: &delete, body: Data(), config: config, credentials: credentials
                )
                _ = try await perform(
                    delete,
                    accepted: [200, 202, 204],
                    minimumSpacing: config.usesCSTCloudCompatibility ? 1.25 : 0
                )
                processedReceipts += 1
            } catch {
                if let cloudError = error as? CloudStorageError,
                   case .http(404, _) = cloudError {
                    continue // Receiver has not committed this pack yet.
                }
                if firstError == nil { firstError = error }
            }
        }
        if !uploadedObjectKeys.isEmpty, processedReceipts == 0, let firstError { throw firstError }
        return confirmed
    }

    private static func validReceipt(_ receipt: CloudRelayReceipt, key: Data) -> Bool {
        guard receipt.hmacSHA256.count == 64,
              let supplied = Data(hexadecimal: receipt.hmacSHA256) else { return false }
        var material = Data("HEALTH-CLOUD-RECEIPT-V1\0".utf8)
        material.append(Data([
            receipt.deviceID,
            receipt.objectKey,
            receipt.packID,
            receipt.committedAt,
            receipt.batchIDs.joined(separator: ","),
        ].joined(separator: "\0").utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(
            supplied,
            authenticating: material,
            using: SymmetricKey(data: key)
        )
    }

    private static func backgroundTransferID(
        config: CloudStorageConfig,
        objectKey: String,
        pack: PreparedRelayPack
    ) -> String {
        let endpoint = config.normalizedEndpoint?.absoluteString ?? ""
        let material = [config.provider.rawValue, endpoint, config.bucket, objectKey]
            .joined(separator: "\0")
        let suffix = SHA256.hash(data: Data(material.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "cloud-\(pack.id)-\(suffix)"
    }

    private static func validateUploadResponse(
        _ response: HTTPURLResponse,
        body: Data
    ) throws {
        if [200, 201, 204].contains(response.statusCode) { return }
        if response.statusCode == 429 {
            throw CloudStorageError.rateLimited(
                rateLimitRetryDate(response: response, consecutiveRateLimits: 1)
            )
        }
        throw CloudStorageError.http(
            response.statusCode,
            String(data: body, encoding: .utf8) ?? ""
        )
    }

    private func validate(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) throws {
        guard config.isConfigured else { throw CloudStorageError.invalidConfiguration }
        guard credentials.isComplete(for: config.provider) else { throw CloudStorageError.missingCredentials }
        if config.normalizedEndpoint?.scheme?.lowercased() != "https",
           config.provider != .directDebug {
            throw CloudStorageError.invalidConfiguration
        }
    }

    private func perform(
        _ request: URLRequest,
        accepted: Set<Int>,
        minimumSpacing: TimeInterval = 0
    ) async throws -> Data {
        let maximumAttempts = 4
        for attempt in 0..<maximumAttempts {
            do {
                try await waitForRequestSlot(minimumSpacing: minimumSpacing)
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudStorageError.invalidResponse
                }
                if accepted.contains(http.statusCode) {
                    consecutiveRateLimits = 0
                    rateLimitedUntil = nil
                    return data
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode == 429 {
                    consecutiveRateLimits += 1
                    let retryAt = Self.rateLimitRetryDate(
                        response: http,
                        consecutiveRateLimits: consecutiveRateLimits
                    )
                    rateLimitedUntil = retryAt
                    throw CloudStorageError.rateLimited(retryAt)
                }
                guard attempt + 1 < maximumAttempts, Self.isRetryable(status: http.statusCode) else {
                    throw CloudStorageError.http(http.statusCode, body)
                }
                try await Self.retryDelay(attempt: attempt, response: http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                guard attempt + 1 < maximumAttempts, Self.isRetryable(error: error) else { throw error }
                try await Self.retryDelay(attempt: attempt, response: nil)
            }
        }
        throw CloudStorageError.invalidResponse
    }

    private func waitForRequestSlot(minimumSpacing: TimeInterval) async throws {
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            throw CloudStorageError.rateLimited(rateLimitedUntil)
        }
        let delay = nextRequestNotBefore.timeIntervalSinceNow
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        nextRequestNotBefore = Date(timeIntervalSinceNow: minimumSpacing)
    }

    private static func rateLimitRetryDate(
        response: HTTPURLResponse,
        consecutiveRateLimits: Int
    ) -> Date {
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value), seconds > 0 {
                return Date(timeIntervalSinceNow: min(seconds, 30 * 60))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: value), date > Date() {
                return min(date, Date(timeIntervalSinceNow: 30 * 60))
            }
        }
        let exponent = Double(max(0, min(consecutiveRateLimits - 1, 5)))
        let seconds = min(30 * pow(2, exponent), 15 * 60) + Double.random(in: 1...5)
        return Date(timeIntervalSinceNow: seconds)
    }

    private static func isRetryable(status: Int) -> Bool {
        [408, 425, 429, 500, 502, 503, 504].contains(status)
    }

    private static func isRetryable(error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    private static func retryDelay(attempt: Int, response: HTTPURLResponse?) async throws {
        if let value = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 30)))
            return
        }
        let base = min(pow(2, Double(attempt)), 8)
        let jitter = Double.random(in: 0.15...0.75)
        try await Task.sleep(for: .seconds(base + jitter))
    }

    private func testS3(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) async throws {
        // Remotely Save also avoids HeadBucket for S3-compatible services and
        // starts with ListObjectsV2. Follow with a real write/read/delete probe
        // so a successful test proves that the permissions needed by sync work.
        let listURL = try S3RequestSigner.url(
            config: config,
            objectKey: nil,
            queryItems: [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "max-keys", value: "1"),
            ]
        )
        var listRequest = URLRequest(url: listURL)
        listRequest.httpMethod = "GET"
        listRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        try S3RequestSigner.sign(
            request: &listRequest,
            body: Data(),
            config: config,
            credentials: credentials
        )
        _ = try await perform(listRequest, accepted: [200])

        let prefix = config.prefix.split(separator: "/").map(String.init)
        let objectKey = (prefix + ["connection-test", "\(UUID().uuidString.lowercased()).bin"])
            .joined(separator: "/")
        let url = try S3RequestSigner.url(config: config, objectKey: objectKey)
        let probe = Data(UUID().uuidString.utf8)
        do {
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.httpBody = probe
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            try S3RequestSigner.sign(request: &put, body: probe, config: config, credentials: credentials)
            _ = try await perform(put, accepted: [200, 201, 204])

            var get = URLRequest(url: url)
            get.httpMethod = "GET"
            try S3RequestSigner.sign(request: &get, body: Data(), config: config, credentials: credentials)
            let downloaded = try await perform(get, accepted: [200])
            guard downloaded == probe else { throw CloudStorageError.invalidResponse }

            try await deleteS3Probe(url: url, config: config, credentials: credentials)
        } catch {
            try? await deleteS3Probe(url: url, config: config, credentials: credentials)
            throw error
        }
    }

    private func deleteS3Probe(
        url: URL,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) async throws {
        var delete = URLRequest(url: url)
        delete.httpMethod = "DELETE"
        try S3RequestSigner.sign(request: &delete, body: Data(), config: config, credentials: credentials)
        _ = try await perform(delete, accepted: [200, 202, 204])
    }

    private func ensureWebDAVCollections(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        components: [String]
    ) async throws {
        guard let base = config.normalizedEndpoint else { throw CloudStorageError.invalidConfiguration }
        var current = base
        for component in components {
            current.append(path: component)
            var request = URLRequest(url: current)
            request.httpMethod = "MKCOL"
            request.setValue(Self.basic(credentials), forHTTPHeaderField: "Authorization")
            _ = try await perform(request, accepted: [200, 201, 204, 405])
        }
    }

    private static func objectDirectoryComponents(
        config: CloudStorageConfig,
        pairing: HealthPairingMaterial
    ) -> [String] {
        let prefix = config.prefix.split(separator: "/").map(String.init)
        return prefix + ["inbox", pairing.deviceID]
    }

    private static func objectKey(
        config: CloudStorageConfig,
        pairing: HealthPairingMaterial,
        pack: PreparedRelayPack
    ) -> String {
        (objectDirectoryComponents(config: config, pairing: pairing)
            + ["\(pack.id).hpack"])
            .joined(separator: "/")
    }

    static func preparePacks(
        candidates: [PendingEncryptedBatch],
        stableIDs: Bool = false
    ) throws -> [PreparedRelayPack] {
        guard !candidates.isEmpty else { return [] }
        var output: [PreparedRelayPack] = []
        var groupID = ""
        for partition in try RelayPackingPolicy.partitions(candidates) {
            if partition.partNumber == 1 {
                groupID = UUID().uuidString.lowercased()
            }
            let stableMaterial = partition.batches
                .map(\.batchID)
                .joined(separator: "\0")
            let stableID = "direct-" + SHA256.hash(data: Data(stableMaterial.utf8))
                .prefix(16)
                .map { String(format: "%02x", $0) }
                .joined()
            output.append(PreparedRelayPack(
                id: stableIDs ? stableID : UUID().uuidString.lowercased(),
                groupID: groupID,
                batches: partition.batches,
                partNumber: partition.partNumber,
                partCount: partition.partCount
            ))
        }
        return output
    }

    static func encode(
        pack: PreparedRelayPack,
        pairing: HealthPairingMaterial
    ) throws -> Data {
        let decoder = JSONDecoder()
        let envelopes = try pack.batches.map {
            try decoder.decode(HealthSyncEnvelope.self, from: Data(contentsOf: $0.url))
        }
        let payload = HealthRelayPack(
            protocol: "health-relay-pack/1",
            packID: pack.id,
            deviceID: pairing.deviceID,
            createdAt: ISO8601DateFormatter.incrementalHealth.string(from: Date()),
            firstSequence: pack.firstSequence,
            lastSequence: pack.lastSequence,
            groupID: pack.groupID,
            partNumber: pack.partNumber,
            partCount: pack.partCount,
            envelopes: envelopes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func appendingPath(_ path: String, to base: URL) -> URL {
        path.split(separator: "/").reduce(base) { partial, component in
            partial.appending(path: String(component))
        }
    }

    private static func basic(_ credentials: CloudStorageCredentials) -> String {
        "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }
}

private final class S3ListObjectsParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private(set) var keys: [String] = []

    static func keys(from data: Data) throws -> [String] {
        let delegate = S3ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw CloudStorageError.invalidResponse }
        return delegate.keys
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" {
            keys.append(currentText)
        }
        currentElement = ""
        currentText = ""
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
            output.append(byte)
            index = end
        }
        self = output
    }
}

private enum S3RequestSigner {
    static func url(
        config: CloudStorageConfig,
        objectKey: String?,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard let endpoint = config.normalizedEndpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host else { throw CloudStorageError.invalidConfiguration }
        let keyComponents = objectKey?.split(separator: "/").map(String.init) ?? []
        if config.pathStyle {
            components.path = append(components.path, components: [config.bucket] + keyComponents)
        } else {
            components.host = "\(config.bucket).\(host)"
            components.path = append(components.path, components: keyComponents)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        }
        guard let url = components.url else { throw CloudStorageError.invalidConfiguration }
        return url
    }

    static func sign(
        request: inout URLRequest,
        body: Data,
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        now: Date = Date()
    ) throws {
        guard let url = request.url, let hostName = url.host else {
            throw CloudStorageError.signing("request URL has no host")
        }
        let dateStamp = dateFormatter("yyyyMMdd").string(from: now)
        let timestamp = dateFormatter("yyyyMMdd'T'HHmmss'Z'").string(from: now)
        let payloadHash = hex(SHA256.hash(data: body))
        let host = url.port.map { "\(hostName):\($0)" } ?? hostName
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if config.usesCSTCloudCompatibility {
            // Data Capsule binds an AccessKey to the client selected at key
            // creation time and returns 401 before S3 processing if the
            // User-Agent does not match. HealthBeat uses the Rclone profile.
            request.setValue("rclone/v1.75.0", forHTTPHeaderField: "User-Agent")
        }

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = urlComponents?.percentEncodedPath
        let canonicalQuery = urlComponents?.percentEncodedQuery ?? ""
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            encodedPath?.isEmpty == false ? encodedPath! : "/",
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
        let dateKey = hmac(Data(("AWS4" + credentials.secretKey).utf8), Data(dateStamp.utf8))
        let regionKey = hmac(dateKey, Data(config.region.utf8))
        let serviceKey = hmac(regionKey, Data("s3".utf8))
        let signingKey = hmac(serviceKey, Data("aws4_request".utf8))
        let signature = hex(hmac(signingKey, Data(stringToSign.utf8)))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func append(_ base: String, components: [String]) -> String {
        let prefix = base.hasSuffix("/") ? String(base.dropLast()) : base
        return prefix + "/" + components.map(percentEncode).joined(separator: "/")
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ value: S) -> String where S.Element == UInt8 {
        value.map { String(format: "%02x", $0) }.joined()
    }
}
