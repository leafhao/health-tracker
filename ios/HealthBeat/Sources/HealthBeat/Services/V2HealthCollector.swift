import Foundation
import HealthKit

struct V2UploadResult: Sendable {
    let uploadedBatches: Int
    let endpoint: URL?
}

struct RecentHealthHistoryAudit: Codable, Sendable {
    let protocolVersion: String
    let startDate: String
    let endDate: String
    let sleepSampleCount: Int
    let sleepBySource: [String: Int]
    let sleepByStage: [String: Int]
    let workoutCount: Int
    let workoutsBySource: [String: Int]
    let workoutsByActivity: [String: Int]
    let activitySummaryCount: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case startDate = "start_date"
        case endDate = "end_date"
        case sleepSampleCount = "sleep_sample_count"
        case sleepBySource = "sleep_by_source"
        case sleepByStage = "sleep_by_stage"
        case workoutCount = "workout_count"
        case workoutsBySource = "workouts_by_source"
        case workoutsByActivity = "workouts_by_activity"
        case activitySummaryCount = "activity_summary_count"
    }
}

private struct DeviceCapabilitiesPayload: Codable, Sendable {
    let deviceID: String
    let appVersion: String?
    let platformVersion: String
    let healthDataAvailable: Bool
    let healthPermissionsRequested: Bool
    let supportedQuantityTypesJSON: String
    let supportedDomainsJSON: String
    let reportedAt: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case appVersion = "app_version"
        case platformVersion = "platform_version"
        case healthDataAvailable = "health_data_available"
        case healthPermissionsRequested = "health_permissions_requested"
        case supportedQuantityTypesJSON = "supported_quantity_types_json"
        case supportedDomainsJSON = "supported_domains_json"
        case reportedAt = "reported_at"
    }
}

private struct V2Receipt: Decodable {
    let batchID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case status
    }
}

private struct V2PackReceipt: Decodable {
    let packID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case packID = "pack_id"
        case status
    }
}

private struct PersistedBackgroundUploadResult: Codable {
    let packID: String
    let statusCode: Int?
    let responseBodyBase64: String
    let errorDescription: String?
    let completedAt: Date
}

/// Owns the system-managed URLSession used by LAN and encrypted cloud uploads.
///
/// The upload body and completion result are files, not process memory. iOS can
/// therefore suspend or relaunch the app while the transfer continues. The
/// caller validates the Receiver receipt before removing anything from outbox.
final class BackgroundHTTPTransferCenter: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = BackgroundHTTPTransferCenter()
    static var sessionIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "org.healthtracker.collector").direct-upload"
    }

    private let lock = NSLock()
    private var responseBodies: [Int: Data] = [:]
    private var backgroundEventsCompletion: (() -> Void)?
    private let directory: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue()
        queue.name = "HealthBeat.BackgroundHTTPTransfer"
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    override private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = support.appending(
            path: "PersonalHealthSync/V2/BackgroundDirectUploads",
            directoryHint: .isDirectory
        )
        super.init()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        _ = session
    }

    func handleEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundEventsCompletion = completionHandler
        lock.unlock()
        _ = session
    }

    func upload(
        request: URLRequest,
        body: Data,
        transferID: String
    ) async throws -> (Data, HTTPURLResponse) {
        if let completed = try consumeResult(transferID: transferID) {
            return completed
        }
        try await schedule(request: request, body: body, transferID: transferID)

        while true {
            try Task.checkCancellation()
            if let completed = try consumeResult(transferID: transferID) {
                return completed
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Hand a file-backed upload to iOS without waiting for the response. This
    /// keeps HealthKit observer completion independent of network latency.
    func schedule(
        request: URLRequest,
        body: Data,
        transferID: String
    ) async throws {
        if FileManager.default.fileExists(atPath: resultURL(transferID: transferID).path) {
            return
        }
        let tasks = await allTasks()
        guard !tasks.contains(where: { $0.taskDescription == transferID }) else { return }
        let bodyURL = bodyURL(transferID: transferID)
        try body.write(
            to: bodyURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var backgroundRequest = request
        backgroundRequest.httpBody = nil
        let task = session.uploadTask(with: backgroundRequest, fromFile: bodyURL)
        task.taskDescription = transferID
        task.resume()
    }

    /// Remove a discretionary transfer before an explicit user-triggered
    /// foreground attempt uploads the same stable S3 object. Cancellation is
    /// bounded; any late delegate callback is harmless and is discarded again
    /// after a successful immediate upload.
    func cancelAndDiscard(transferID: String) async {
        let matching = await allTasks().filter { $0.taskDescription == transferID }
        matching.forEach { $0.cancel() }
        for _ in 0..<10 {
            if (await allTasks()).allSatisfy({ $0.taskDescription != transferID }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: bodyURL(transferID: transferID))
        try? FileManager.default.removeItem(at: resultURL(transferID: transferID))
    }

    /// An explicit shortcut upload supersedes older discretionary S3 tasks,
    /// because its stable pack includes every still-unmarked batch. LAN direct
    /// uploads use the `direct-` prefix and are intentionally unaffected.
    func cancelAndDiscardCloudTransfers() async {
        let matching = await allTasks().filter {
            $0.taskDescription?.hasPrefix("cloud-") == true
        }
        matching.forEach { $0.cancel() }
        for _ in 0..<10 {
            if (await allTasks()).allSatisfy({
                $0.taskDescription?.hasPrefix("cloud-") != true
            }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("cloud-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Consume a completion persisted while the process was suspended. The
    /// result file is removed exactly once; callers either commit its upload
    /// marker or safely schedule the stable pack again.
    func consumeCompletedResult(
        transferID: String
    ) throws -> (Data, HTTPURLResponse)? {
        try consumeResult(transferID: transferID)
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func consumeResult(transferID: String) throws -> (Data, HTTPURLResponse)? {
        let target = resultURL(transferID: transferID)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let result = try JSONDecoder().decode(
            PersistedBackgroundUploadResult.self,
            from: Data(contentsOf: target)
        )
        try? FileManager.default.removeItem(at: target)
        let data = Data(base64Encoded: result.responseBodyBase64) ?? Data()
        if let message = result.errorDescription {
            throw SyncError.backgroundTransfer(message)
        }
        guard let statusCode = result.statusCode,
              let response = HTTPURLResponse(
                url: URL(string: "http://background-transfer.local")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              ) else {
            throw SyncError.invalidResponse
        }
        return (data, response)
    }

    private func persistResult(
        task: URLSessionTask,
        error: Error?
    ) {
        guard let transferID = task.taskDescription else { return }
        lock.lock()
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let result = PersistedBackgroundUploadResult(
            packID: transferID,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            responseBodyBase64: body.base64EncodedString(),
            errorDescription: error?.localizedDescription,
            completedAt: Date()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(result).write(
                to: resultURL(transferID: transferID),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // Keep the outbox untouched. A foreground retry remains safe because
            // Receiver pack ingestion is idempotent.
            print("[BackgroundHTTPTransfer] unable to persist result: \(error)")
        }
        try? FileManager.default.removeItem(at: bodyURL(transferID: transferID))
    }

    private func safeName(_ transferID: String) -> String {
        transferID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func bodyURL(transferID: String) -> URL {
        directory.appending(path: "\(safeName(transferID)).upload")
    }

    private func resultURL(transferID: String) -> URL {
        directory.appending(path: "\(safeName(transferID)).result.json")
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        persistResult(task: task, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        DispatchQueue.main.async {
            V2BackgroundSyncCoordinator.shared.scheduleNext(earliest: 60)
            completion?()
        }
    }
}

@available(iOS 17.0, *)
actor DirectEncryptedBatchUploader {
    private let transfers = BackgroundHTTPTransferCenter.shared

    func flush(
        outbox: EncryptedHealthOutbox,
        baseURLs: [URL],
        pairing: HealthPairingMaterial,
        progress: (@Sendable (Int, Int, Int, Int) async -> Void)? = nil
    ) async throws -> V2UploadResult {
        guard !baseURLs.isEmpty else { throw SyncError.notConfigured }
        var uploaded = 0
        var lastEndpoint: URL?
        let packs = try CloudRelayTransport.preparePacks(
            candidates: try await outbox.pending(),
            stableIDs: true
        )
        let totalBatches = packs.reduce(0) { $0 + $1.batches.count }
        await progress?(0, totalBatches, 0, packs.count)
        for (packIndex, pack) in packs.enumerated() {
            try Task.checkCancellation()
            let body = try CloudRelayTransport.encode(pack: pack, pairing: pairing)
            var lastError: Error = SyncError.noReachableEndpoint
            var delivered = false
            for baseURL in baseURLs {
                do {
                    let endpoint = baseURL.appending(path: "api/v2/sync/packs")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (responseData, http) = try await transfers.upload(
                        request: request,
                        body: body,
                        transferID: "direct-\(pack.id)"
                    )
                    guard (200..<300).contains(http.statusCode) else {
                        throw SyncError.http(
                            http.statusCode,
                            String(data: responseData, encoding: .utf8) ?? ""
                        )
                    }
                    let receipt = try JSONDecoder().decode(V2PackReceipt.self, from: responseData)
                    guard receipt.packID == pack.id, receipt.status == "committed" else {
                        throw SyncError.invalidResponse
                    }
                    for batch in pack.batches {
                        try await outbox.remove(batch)
                    }
                    uploaded += pack.batches.count
                    await progress?(uploaded, totalBatches, packIndex + 1, packs.count)
                    lastEndpoint = baseURL
                    delivered = true
                    break
                } catch {
                    lastError = error
                }
            }
            if !delivered { throw lastError }
        }
        return V2UploadResult(uploadedBatches: uploaded, endpoint: lastEndpoint)
    }
}

@available(iOS 17.0, *)
final class V2HealthCollector: @unchecked Sendable {
    private let healthKit: HealthKitService
    private let query: HealthAnchoredQueryService
    private let anchors: HealthAnchorStore
    private let outbox: EncryptedHealthOutbox
    private let cloudTransport = CloudRelayTransport()

    init(healthKit: HealthKitService = .shared) {
        self.healthKit = healthKit
        query = HealthAnchoredQueryService(store: healthKit.store)
        let anchors = HealthAnchorStore()
        self.anchors = anchors
        outbox = EncryptedHealthOutbox(anchorStore: anchors)
    }

    /// Read-only audit used to compare what HealthKit currently exposes with
    /// what the Receiver stored. It never creates an outbox batch or advances
    /// an anchor, so a diagnostic cannot accidentally start another backfill.
    func auditRecentHistory(days: Int = 30, referenceDate: Date = Date()) async throws
        -> RecentHealthHistoryAudit {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -max(1, days), to: referenceDate)
            ?? referenceDate.addingTimeInterval(-Double(max(1, days)) * 86_400)
        var sleepCount = 0
        var sleepBySource: [String: Int] = [:]
        var sleepByStage: [String: Int] = [:]
        let sleepDescriptor = HealthDataTypes.categoryDescriptor(
            for: HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        )
        try await healthKit.streamCategorySamples(
            typeID: .sleepAnalysis,
            from: startDate,
            until: referenceDate,
            batchSize: 5_000
        ) { samples in
            for sample in samples {
                sleepCount += 1
                sleepBySource[sample.sourceDisplayName, default: 0] += 1
                let stage = sleepDescriptor?.valueLabels[sample.value] ?? "value:\(sample.value)"
                sleepByStage[stage, default: 0] += 1
            }
        }

        var workoutCount = 0
        var workoutsBySource: [String: Int] = [:]
        var workoutsByActivity: [String: Int] = [:]
        try await healthKit.streamWorkouts(
            from: startDate,
            until: referenceDate,
            batchSize: 1_000
        ) { workouts in
            for workout in workouts {
                workoutCount += 1
                workoutsBySource[workout.sourceDisplayName, default: 0] += 1
                workoutsByActivity[workout.activityTypeName, default: 0] += 1
            }
        }
        let summaries = try await healthKit.fetchActivitySummaries(
            from: startDate,
            until: referenceDate
        )
        return RecentHealthHistoryAudit(
            protocolVersion: "health-history-audit/1",
            startDate: ISO8601DateFormatter.incrementalHealth.string(from: startDate),
            endDate: ISO8601DateFormatter.incrementalHealth.string(from: referenceDate),
            sleepSampleCount: sleepCount,
            sleepBySource: sleepBySource,
            sleepByStage: sleepByStage,
            workoutCount: workoutCount,
            workoutsBySource: workoutsBySource,
            workoutsByActivity: workoutsByActivity,
            activitySummaryCount: summaries.count
        )
    }

    func collect(
        quantityDescriptors: [QuantityTypeDescriptor],
        changedTypeIdentifiers: Set<String>? = nil,
        bootstrapCutoff: Date? = nil,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        var eventCount = 0
        for descriptor in quantityDescriptors {
            guard let type = descriptor.hkType else { continue }
            if let changedTypeIdentifiers, !changedTypeIdentifiers.contains(descriptor.id) { continue }
            eventCount += try await collectQuantity(
                descriptor: descriptor,
                type: type,
                bootstrapCutoff: bootstrapCutoff,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
        }
        let sleepIdentifier = HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        if (changedTypeIdentifiers == nil || changedTypeIdentifiers!.contains(sleepIdentifier)),
           let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            eventCount += try await collectSleep(
                type: sleep,
                bootstrapCutoff: bootstrapCutoff,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
        }
        let workoutIdentifier = HKObjectType.workoutType().identifier
        let routeIdentifier = HKSeriesType.workoutRoute().identifier
        if changedTypeIdentifiers == nil
            || changedTypeIdentifiers!.contains(workoutIdentifier)
            || changedTypeIdentifiers!.contains(routeIdentifier) {
            eventCount += try await collectWorkouts(
                bootstrapCutoff: bootstrapCutoff,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
        }
        if changedTypeIdentifiers == nil {
            eventCount += try await collectActivitySummaries(
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
            eventCount += try await collectDeviceCapabilities(
                quantityDescriptors: quantityDescriptors,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
        }
        return eventCount
    }

    /// Performs a date-bounded, reliable bulk read for the first historical sync.
    /// Anchored queries are intentionally not used here: with a nil anchor HealthKit
    /// can omit older samples for some types because anchors are change cursors, not
    /// a complete-history export API.
    func collectHistory(
        quantityDescriptors: [QuantityTypeDescriptor],
        from startDate: Date?,
        until endDate: Date,
        relayGroup: String,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data,
        progress: @escaping @Sendable (_ label: String, _ eventCount: Int) async -> Void
    ) async throws -> Int {
        var total = 0

        for descriptor in quantityDescriptors {
            try Task.checkCancellation()
            try await healthKit.streamQuantitySamples(
                typeID: descriptor.hkIdentifier,
                from: startDate,
                until: endDate,
                batchSize: 1_000
            ) { [self] samples in
                let events = try samples.map { try quantityEvent(sample: $0, descriptor: descriptor) }
                try await enqueueChunks(
                    events,
                    streamID: "history/\(descriptor.id)",
                    newAnchor: nil,
                    pairing: pairing,
                    signingPrivateKey: signingPrivateKey,
                    relayGroup: relayGroup
                )
                total += events.count
                await progress(descriptor.displayName, total)
            }
        }

        try Task.checkCancellation()
        try await healthKit.streamCategorySamples(
            typeID: .sleepAnalysis,
            from: startDate,
            until: endDate,
            batchSize: 1_000
        ) { [self] samples in
            let events = try samples.map { try sleepEvent(sample: $0) }
            try await enqueueChunks(
                events,
                streamID: "history/\(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)",
                newAnchor: nil,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey,
                relayGroup: relayGroup
            )
            total += events.count
            await progress("睡眠", total)
        }

        try Task.checkCancellation()
        try await healthKit.streamWorkouts(
            from: startDate,
            until: endDate,
            batchSize: 200
        ) { [self] workouts in
            var events: [HealthEvent] = []
            for workout in workouts {
                events.append(contentsOf: try await workoutEvents(workout))
            }
            try await enqueueChunks(
                events,
                streamID: "history/workouts",
                newAnchor: nil,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey,
                relayGroup: relayGroup
            )
            total += events.count
            await progress("锻炼与路线", total)
        }

        try Task.checkCancellation()
        // HealthKit's activity-summary query only applies an end boundary when a
        // start boundary is also supplied. 1970 still means "all available" for
        // practical Apple Health data while preserving the requested gap end.
        let summaryStart = startDate ?? Date(timeIntervalSince1970: 0)
        let summaries = try await healthKit.fetchActivitySummaries(from: summaryStart, until: endDate)
        let activityEvents = try activitySummaryEvents(summaries)
        try await enqueueChunks(
            activityEvents,
            streamID: "history/activity-summary-daily",
            newAnchor: nil,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey,
            relayGroup: relayGroup
        )
        total += activityEvents.count
        await progress("活动圆环", total)
        return total
    }

    /// Bounded repair for the independent non-quantity streams. This exists so
    /// a legacy completion-state bug can be corrected without retransmitting
    /// the much larger quantity history.
    func collectDomainHistory(
        from startDate: Date,
        until endDate: Date,
        relayGroup: String,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data,
        progress: @escaping @Sendable (_ label: String, _ eventCount: Int) async -> Void
    ) async throws -> Int {
        var total = 0

        try Task.checkCancellation()
        try await healthKit.streamCategorySamples(
            typeID: .sleepAnalysis,
            from: startDate,
            until: endDate,
            batchSize: 1_000
        ) { [self] samples in
            let events = try samples.map { try sleepEvent(sample: $0) }
            if !events.isEmpty {
                try await enqueueChunks(
                    events,
                    streamID: "repair/\(HKCategoryTypeIdentifier.sleepAnalysis.rawValue)",
                    newAnchor: nil,
                    pairing: pairing,
                    signingPrivateKey: signingPrivateKey,
                    relayGroup: relayGroup
                )
            }
            total += events.count
            await progress("Apple Watch 睡眠", total)
        }

        try Task.checkCancellation()
        try await healthKit.streamWorkouts(
            from: startDate,
            until: endDate,
            batchSize: 200
        ) { [self] workouts in
            var events: [HealthEvent] = []
            for workout in workouts {
                events.append(contentsOf: try await workoutEvents(workout))
            }
            if !events.isEmpty {
                try await enqueueChunks(
                    events,
                    streamID: "repair/workouts",
                    newAnchor: nil,
                    pairing: pairing,
                    signingPrivateKey: signingPrivateKey,
                    relayGroup: relayGroup
                )
            }
            total += events.count
            await progress("锻炼与路线", total)
        }

        try Task.checkCancellation()
        let summaries = try await healthKit.fetchActivitySummaries(
            from: startDate,
            until: endDate
        )
        let activityEvents = try activitySummaryEvents(summaries)
        if !activityEvents.isEmpty {
            try await enqueueChunks(
                activityEvents,
                streamID: "repair/activity-summary-daily",
                newAnchor: nil,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey,
                relayGroup: relayGroup
            )
        }
        total += activityEvents.count
        await progress("活动圆环", total)
        return total
    }

    func earliestAvailableDate(
        quantityDescriptors: [QuantityTypeDescriptor]
    ) async throws -> Date? {
        var earliest: Date?
        for descriptor in quantityDescriptors {
            guard let type = descriptor.hkType else { continue }
            if let date = try await healthKit.earliestSampleDate(for: type) {
                earliest = min(earliest ?? date, date)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
           let date = try await healthKit.earliestSampleDate(for: sleep) {
            earliest = min(earliest ?? date, date)
        }
        if let date = try await healthKit.earliestSampleDate(for: HKObjectType.workoutType()) {
            earliest = min(earliest ?? date, date)
        }
        return earliest
    }

    func pendingBatchCount() async throws -> Int {
        try await outbox.pending().count
    }

    func outboxCounts(provider: CloudStorageProvider) async throws -> EncryptedOutboxCounts {
        try await outbox.counts(provider: provider)
    }

    func initialDirectProgressSnapshot() async throws -> InitialDirectProgressSnapshot {
        try await outbox.initialDirectProgressSnapshot()
    }

    func persistedAnchorCount() async throws -> Int {
        try await anchors.persistedAnchorCount()
    }

    func flush(config: ReceiverConfig) async throws -> V2UploadResult {
        let loaded = try await HealthV2PairingService.shared.load()
        return try await DirectEncryptedBatchUploader().flush(
            outbox: outbox,
            baseURLs: config.baseURLs,
            pairing: loaded.material
        )
    }

    func flushDirect(
        baseURLs: [URL],
        pairing: HealthPairingMaterial,
        progress: (@Sendable (Int, Int, Int, Int) async -> Void)? = nil
    ) async throws -> V2UploadResult {
        try await DirectEncryptedBatchUploader().flush(
            outbox: outbox,
            baseURLs: baseURLs,
            pairing: pairing,
            progress: progress
        )
    }

    func flushCloud(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        pairing: HealthPairingMaterial
    ) async throws -> CloudRelayUploadResult {
        try await cloudTransport.uploadPending(
            outbox: outbox,
            pairing: pairing,
            config: config,
            credentials: credentials
        )
    }

    func scheduleCloudUpload(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        pairing: HealthPairingMaterial
    ) async throws -> Int {
        try await cloudTransport.schedulePending(
            outbox: outbox,
            pairing: pairing,
            config: config,
            credentials: credentials
        )
    }

    func uploadOneCloudPackImmediately(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        pairing: HealthPairingMaterial,
        timeout: TimeInterval = 30
    ) async throws -> Int {
        try await cloudTransport.uploadOnePendingImmediately(
            outbox: outbox,
            pairing: pairing,
            config: config,
            credentials: credentials,
            timeout: timeout
        )
    }

    func reconcileCloudReceipts(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials,
        pairing: HealthPairingMaterial
    ) async throws -> Int {
        try await cloudTransport.reconcileReceipts(
            outbox: outbox,
            pairing: pairing,
            config: config,
            credentials: credentials
        )
    }

    private func collectQuantity(
        descriptor: QuantityTypeDescriptor,
        type: HKQuantityType,
        bootstrapCutoff: Date?,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        let streamID = descriptor.id
        return try await collectAnchoredStream(
            streamID: streamID,
            type: type,
            entityType: .quantity,
            bootstrapCutoff: bootstrapCutoff,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey
        ) { sample in
            guard let sample = sample as? HKQuantitySample else { return nil }
            return [try self.quantityEvent(sample: sample, descriptor: descriptor)]
        }
    }

    private func collectSleep(
        type: HKCategoryType,
        bootstrapCutoff: Date?,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        let streamID = HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        let descriptor = HealthDataTypes.categoryDescriptor(for: streamID)
        return try await collectAnchoredStream(
            streamID: streamID,
            type: type,
            entityType: .category,
            bootstrapCutoff: bootstrapCutoff,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey
        ) { sample in
            guard let sample = sample as? HKCategorySample else { return nil }
            return [try self.sleepEvent(sample: sample, descriptor: descriptor)]
        }
    }

    private func collectWorkouts(
        bootstrapCutoff: Date?,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        try await collectAnchoredStream(
            streamID: HKObjectType.workoutType().identifier,
            type: HKObjectType.workoutType(),
            entityType: .workout,
            bootstrapCutoff: bootstrapCutoff,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey
        ) { [healthKit] sample in
            guard let workout = sample as? HKWorkout else { return nil }
            _ = healthKit // Keep the explicit capture so the async closure remains Sendable-safe.
            return try await self.workoutEvents(workout)
        }
    }

    private func collectActivitySummaries(
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: Date()))
        let summaries = try await healthKit.fetchActivitySummaries(from: start, until: Date())
        let events = try activitySummaryEvents(summaries)
        try await enqueueChunks(
            events,
            streamID: "activity-summary-daily",
            newAnchor: nil,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey
        )
        return events.count
    }

    private func collectDeviceCapabilities(
        quantityDescriptors: [QuantityTypeDescriptor],
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        let now = Date()
        let supportedTypes = quantityDescriptors.map(\.id).sorted()
        let domains = ["sleep", "workout", "workout_route", "activity_summary"]
        let payload = DeviceCapabilitiesPayload(
            deviceID: pairing.deviceID,
            appVersion: (
                Bundle.main.object(forInfoDictionaryKey: "HealthTrackerProductVersion")
                    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            ) as? String,
            platformVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            healthDataAvailable: HKHealthStore.isHealthDataAvailable(),
            healthPermissionsRequested: UserDefaults.standard.bool(
                forKey: "personalReceiver.healthPermissionRequested"
            ),
            supportedQuantityTypesJSON: String(
                data: try JSONEncoder().encode(supportedTypes),
                encoding: .utf8
            ) ?? "[]",
            supportedDomainsJSON: String(
                data: try JSONEncoder().encode(domains),
                encoding: .utf8
            ) ?? "[]",
            reportedAt: Self.timestamp(now)
        )
        let event = try HealthEvent.upsert(
            entityType: .deviceCapabilities,
            sourceUUID: pairing.deviceID,
            observedAt: now,
            payload: payload
        )
        try await enqueueChunks(
            [event],
            streamID: "device-capabilities",
            newAnchor: nil,
            pairing: pairing,
            signingPrivateKey: signingPrivateKey
        )
        return 1
    }

    private func collectAnchoredStream(
        streamID: String,
        type: HKSampleType,
        entityType: HealthEntityType,
        bootstrapCutoff: Date?,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data,
        makeUpsert: @escaping (HKSample) async throws -> [HealthEvent]?
    ) async throws -> Int {
        var anchor = try await anchors.load(streamID: streamID)
        let isBootstrap = anchor == nil
        var total = 0
        for _ in 0..<1_000 {
            let page = try await query.fetchChangesPage(for: type, anchor: anchor, limit: 500)
            var events: [HealthEvent] = []
            for sample in page.added {
                if isBootstrap, let bootstrapCutoff, sample.endDate < bootstrapCutoff {
                    continue
                }
                if let sampleEvents = try await makeUpsert(sample) {
                    events.append(contentsOf: sampleEvents)
                }
            }
            events.append(contentsOf: page.deleted.map {
                HealthEvent.delete(entityType: entityType, sourceUUID: $0.uuid.uuidString)
            })
            try await enqueueChunks(
                events,
                streamID: streamID,
                newAnchor: page.newAnchor,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            )
            total += events.count
            anchor = page.newAnchor
            if page.added.count + page.deleted.count < 500 { return total }
        }
        throw IncrementalSyncError.tooManyAnchorPages(streamID)
    }

    private func quantityEvent(
        sample: HKQuantitySample,
        descriptor: QuantityTypeDescriptor
    ) throws -> HealthEvent {
        let row = HBQuantityRow(
            uuid: sample.uuid.uuidString,
            type: descriptor.id,
            value: sample.quantity.doubleValue(for: descriptor.unit),
            unit: descriptor.unitString,
            start_date: Self.timestamp(sample.startDate),
            end_date: Self.timestamp(sample.endDate),
            source_name: sample.sourceDisplayName,
            source_bundle_id: sample.sourceBundleID,
            device_name: sample.deviceName,
            metadata: sample.jsonMetadata()
        )
        return try HealthEvent.upsert(
            entityType: .quantity,
            sourceUUID: row.uuid,
            observedAt: sample.endDate,
            payload: row
        )
    }

    private func sleepEvent(
        sample: HKCategorySample,
        descriptor: CategoryTypeDescriptor? = HealthDataTypes.categoryDescriptor(
            for: HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        )
    ) throws -> HealthEvent {
        let row = HBCategoryRow(
            uuid: sample.uuid.uuidString,
            type: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
            value: sample.value,
            value_label: descriptor?.valueLabels[sample.value],
            start_date: Self.timestamp(sample.startDate),
            end_date: Self.timestamp(sample.endDate),
            source_name: sample.sourceDisplayName,
            source_bundle_id: sample.sourceBundleID,
            device_name: sample.deviceName,
            metadata: Self.metadataJSON(sample.metadata)
        )
        return try HealthEvent.upsert(
            entityType: .category,
            sourceUUID: row.uuid,
            observedAt: sample.endDate,
            payload: row
        )
    }

    private func workoutEvents(_ workout: HKWorkout) async throws -> [HealthEvent] {
        let row = HBWorkoutRow(
            uuid: workout.uuid.uuidString,
            activity_type: workout.activityTypeName,
            duration_seconds: workout.duration,
            total_energy_burned_kcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            total_distance_meters: workout.totalDistance?.doubleValue(for: .meter()),
            total_swimming_strokes: workout.totalSwimmingStrokeCount?.doubleValue(for: .count()),
            total_flights_climbed: workout.totalFlightsClimbed?.doubleValue(for: .count()),
            start_date: Self.timestamp(workout.startDate),
            end_date: Self.timestamp(workout.endDate),
            source_name: workout.sourceDisplayName,
            source_bundle_id: workout.sourceBundleID,
            device_name: workout.deviceName,
            metadata: Self.metadataJSON(workout.metadata)
        )
        var events = [try HealthEvent.upsert(
            entityType: .workout,
            sourceUUID: row.uuid,
            observedAt: workout.endDate,
            payload: row
        )]
        for route in try await healthKit.fetchWorkoutRoutes(for: workout) {
            let locations = try await healthKit.fetchRouteLocations(for: route)
            let locationObjects: [[String: Any]] = locations.map { location in
                [
                    "latitude": location.coordinate.latitude,
                    "longitude": location.coordinate.longitude,
                    "altitude": location.altitude,
                    "horizontal_accuracy": location.horizontalAccuracy,
                    "vertical_accuracy": location.verticalAccuracy,
                    "speed": location.speed,
                    "course": location.course,
                    "timestamp": Self.timestamp(location.timestamp),
                ]
            }
            let locationData = try JSONSerialization.data(withJSONObject: locationObjects)
            let routeRow = HBWorkoutRouteRow(
                uuid: route.uuid.uuidString,
                workout_uuid: workout.uuid.uuidString,
                start_date: Self.timestamp(route.startDate),
                location_count: locations.count,
                locations_json: String(data: locationData, encoding: .utf8)
            )
            events.append(try HealthEvent.upsert(
                entityType: .workoutRoute,
                sourceUUID: routeRow.uuid,
                observedAt: workout.endDate,
                payload: routeRow
            ))
        }
        return events
    }

    private func activitySummaryEvents(_ summaries: [HKActivitySummary]) throws -> [HealthEvent] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return try summaries.compactMap { summary -> HealthEvent? in
            guard let date = calendar.date(from: summary.dateComponents(for: calendar)) else { return nil }
            let row = HBActivitySummaryRow(
                date: formatter.string(from: date),
                active_energy_burned: summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                active_energy_burned_goal: summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                exercise_time_minutes: summary.appleExerciseTime.doubleValue(for: .minute()),
                exercise_time_goal_minutes: summary.appleExerciseTimeGoal.doubleValue(for: .minute()),
                stand_hours: Int(summary.appleStandHours.doubleValue(for: .count())),
                stand_hours_goal: Int(summary.appleStandHoursGoal.doubleValue(for: .count()))
            )
            return try HealthEvent.upsert(
                entityType: .activitySummary,
                sourceUUID: row.date,
                observedAt: date,
                payload: row
            )
        }
    }

    private func enqueueChunks(
        _ events: [HealthEvent],
        streamID: String,
        newAnchor: HKQueryAnchor?,
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data,
        relayGroup: String? = nil
    ) async throws {
        if events.isEmpty {
            _ = try await outbox.enqueue(
                streamID: streamID,
                events: [],
                newAnchor: newAnchor,
                pairing: pairing,
                deviceSigningPrivateKey: signingPrivateKey,
                relayGroup: relayGroup
            )
            return
        }
        let chunks = events.chunkedV2(size: 400)
        for (index, chunk) in chunks.enumerated() {
            _ = try await outbox.enqueue(
                streamID: streamID,
                events: chunk,
                newAnchor: index == chunks.count - 1 ? newAnchor : nil,
                pairing: pairing,
                deviceSigningPrivateKey: signingPrivateKey,
                relayGroup: relayGroup
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.incrementalHealth.string(from: date)
    }

    private static func metadataJSON(_ metadata: [String: Any]?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }
        let safe = metadata.mapValues { value -> String in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return String(describing: value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: safe) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Array {
    func chunkedV2(size: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
