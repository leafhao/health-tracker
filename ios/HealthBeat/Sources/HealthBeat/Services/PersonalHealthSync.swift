import CoreLocation
import Foundation
import HealthKit
import Security

// MARK: - Configuration and secrets

enum InitialHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case days30
    case days90
    case oneYear
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .days30: return "最近 30 天"
        case .days90: return "最近 90 天"
        case .oneYear: return "最近 1 年（推荐）"
        case .all: return "全部可用历史"
        }
    }

    var workloadDescription: String {
        switch self {
        case .days30:
            return "数据量较小，适合先快速验证同步流程。"
        case .days90:
            return "数据量适中，通常可覆盖近期睡眠和训练趋势。"
        case .oneYear:
            return "推荐选择，能够分析季节变化和长期趋势，首次同步耗时仍可控。"
        case .all:
            return "可能包含数年、上百万条原始样本，首次同步可能持续很久并占用大量空间。"
        }
    }

    func startDate(relativeTo date: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .days30: return calendar.date(byAdding: .day, value: -30, to: date)
        case .days90: return calendar.date(byAdding: .day, value: -90, to: date)
        case .oneYear: return calendar.date(byAdding: .year, value: -1, to: date)
        case .all: return nil
        }
    }
}

struct ReceiverConfig: Equatable, Sendable {
    var localURL: String
    var remoteURL: String
    var pairingCode: String

    static let empty = ReceiverConfig(localURL: "", remoteURL: "", pairingCode: "")
    private static let localKey = "personalReceiver.localURL"
    private static let remoteKey = "personalReceiver.remoteURL"
    private static let pairingCodeAccount = "receiverOneTimePairingCode"

    static func load() -> ReceiverConfig {
        ReceiverConfig(
            localURL: UserDefaults.standard.string(forKey: localKey) ?? "",
            remoteURL: UserDefaults.standard.string(forKey: remoteKey) ?? "",
            pairingCode: (try? KeychainStore.read(account: pairingCodeAccount)) ?? ""
        )
    }

    func save() throws {
        UserDefaults.standard.set(localURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.localKey)
        UserDefaults.standard.set(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.remoteKey)
        try KeychainStore.write(pairingCode, account: Self.pairingCodeAccount)
    }

    static func clearPairingCode() throws {
        try KeychainStore.write("", account: pairingCodeAccount)
    }

    var baseURLs: [URL] {
        [localURL, remoteURL]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { raw -> URL? in
                let value = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
                return url
            }
    }

    var isConfigured: Bool { !pairingCode.isEmpty && !baseURLs.isEmpty }
}

enum KeychainStore {
    private static var service: String { Bundle.main.bundleIdentifier ?? "PersonalHealthSync" }

    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw SyncError.keychain(status) }
    }

    static func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SyncError.keychain(status)
        }
        return value
    }
}

// MARK: - Durable HTTP queue

private struct UploadJob: Codable, Sendable {
    let id: UUID
    let endpoint: String
    let createdAt: Date
    let body: Data
}

private actor UploadQueue {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appending(path: "PersonalHealthSync/UploadQueue", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func enqueue(endpoint: String, body: Data) throws -> UploadJob {
        let job = UploadJob(id: UUID(), endpoint: endpoint, createdAt: Date(), body: body)
        let data = try encoder.encode(job)
        try data.write(to: url(for: job), options: .atomic)
        return job
    }

    func pending() -> [UploadJob] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(UploadJob.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ job: UploadJob) throws {
        let target = url(for: job)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    func count() -> Int { pending().count }

    private func url(for job: UploadJob) -> URL {
        directory.appending(path: "\(job.id.uuidString).json")
    }
}

private actor ReceiverClient {
    private let session: URLSession
    private var cachedBaseURL: URL?
    private var cacheDate: Date = .distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func test(config: ReceiverConfig) async throws -> URL {
        guard !config.baseURLs.isEmpty else { throw SyncError.notConfigured }
        var sawHealthyEndpoint = false
        for baseURL in orderedCandidates(config: config) {
            guard await isHealthy(baseURL) else { continue }
            sawHealthyEndpoint = true
            if await tokenStatus(baseURL, token: config.pairingCode) == 200 {
                cachedBaseURL = baseURL
                cacheDate = Date()
                return baseURL
            }
        }
        if sawHealthyEndpoint { throw SyncError.tokenRejected }
        throw SyncError.noReachableEndpoint
    }

    func send(_ job: UploadJob, config: ReceiverConfig) async throws -> URL {
        guard config.isConfigured else { throw SyncError.notConfigured }
        var lastError: Error = SyncError.noReachableEndpoint
        for baseURL in orderedCandidates(config: config) {
            do {
                if cachedBaseURL != baseURL || Date().timeIntervalSince(cacheDate) > 600 {
                    guard await isHealthy(baseURL) else { continue }
                }
                let url = baseURL.appending(path: job.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = job.body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(config.pairingCode)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw SyncError.http(http.statusCode, body)
                }
                cachedBaseURL = baseURL
                cacheDate = Date()
                return baseURL
            } catch {
                lastError = error
                if cachedBaseURL == baseURL { cachedBaseURL = nil }
            }
        }
        throw lastError
    }

    private func orderedCandidates(config: ReceiverConfig) -> [URL] {
        var candidates = config.baseURLs
        if let cachedBaseURL,
           Date().timeIntervalSince(cacheDate) <= 600,
           let index = candidates.firstIndex(of: cachedBaseURL) {
            candidates.remove(at: index)
            candidates.insert(cachedBaseURL, at: 0)
        }
        return candidates
    }

    private func isHealthy(_ baseURL: URL) async -> Bool {
        let url = baseURL.appending(path: "api/v1/healthbeat/health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[ReceiverClient] health \(url.absoluteString) failed: non-HTTP response")
                return false
            }
            guard http.statusCode == 200 else {
                print("[ReceiverClient] health \(url.absoluteString) failed: HTTP \(http.statusCode)")
                return false
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let healthy = object?["status"] as? String == "ok"
            if !healthy {
                print("[ReceiverClient] health \(url.absoluteString) failed: invalid payload")
            }
            return healthy
        } catch {
            print("[ReceiverClient] health \(url.absoluteString) failed: \(error)")
            return false
        }
    }

    private func tokenStatus(_ baseURL: URL, token: String) async -> Int? {
        let url = baseURL.appending(path: "api/v1/healthbeat/quantity-samples")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"records\":[]}".utf8)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[ReceiverClient] token check \(url.absoluteString) failed: non-HTTP response")
                return nil
            }
            if !(200..<300).contains(http.statusCode) {
                print("[ReceiverClient] token check \(url.absoluteString) failed: HTTP \(http.statusCode)")
            }
            return http.statusCode
        } catch {
            print("[ReceiverClient] token check \(url.absoluteString) failed: \(error)")
            return nil
        }
    }
}

// MARK: - HealthKit collection

enum SyncError: Error, LocalizedError {
    case notConfigured
    case noReachableEndpoint
    case tokenRejected
    case invalidResponse
    case http(Int, String)
    case backgroundTransfer(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先填写接收端地址和一次性配对码"
        case .noReachableEndpoint: return "局域网和 Tailscale 地址都无法访问"
        case .tokenRejected: return "Receiver 可以访问，但凭据被拒绝"
        case .invalidResponse: return "接收端返回了无效响应"
        case .http(let code, let body): return "接收端 HTTP \(code)：\(body.prefix(300))"
        case .backgroundTransfer(let message): return "后台传输失败：\(message)"
        case .keychain(let status): return "Keychain 操作失败（\(status)）"
        }
    }
}

private struct WireEnvelope<T: Encodable>: Encodable { let records: [T] }

@MainActor
final class PersonalHealthSyncService: ObservableObject {
    static let shared = PersonalHealthSyncService()

    @Published private(set) var isSyncing = false
    @Published private(set) var isTestingCloud = false
    @Published private(set) var statusMessage = "等待配置"
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastEndpoint = ""
    @Published private(set) var uploadedRecords = 0
    @Published private(set) var pendingBatches = 0
    @Published private(set) var isV2Paired = false
    @Published private(set) var awaitingCloudUpload = 0
    @Published private(set) var awaitingCloudPacks = 0
    @Published private(set) var awaitingReceiver = 0
    @Published private(set) var cloudStatusMessage = "尚未配置"
    @Published private(set) var cloudProviderName = "未配置"
    @Published private(set) var receiverStatusMessage = "尚未测试"
    @Published private(set) var initialHistoryRange: InitialHistoryRange = .oneYear
    @Published private(set) var isInitialHistoryRangeConfirmed = false
    @Published private(set) var historicalCoverageStart: Date?
    @Published private(set) var hasCompleteHistory = false
    @Published private(set) var historicalSyncMessage = "尚未执行首次历史回溯"
    @Published private(set) var isInitialDirectBootstrapComplete = false
    @Published private(set) var initialDirectTotalBatches = 0
    @Published private(set) var initialDirectCompletedBatches = 0
    @Published private(set) var initialDirectRemainingBatches = 0
    @Published private(set) var initialDirectRemainingPacks = 0
    @Published var errorMessage: String?

    private let healthKit = HealthKitService.shared
    private let queue = UploadQueue()
    private let client = ReceiverClient()
    private let v2Collector = V2HealthCollector()
    private let cloudTransport = CloudRelayTransport()
    private var observerQueries: [HKObserverQuery] = []
    private var observersStarted = false
    private var pendingObserverTypes: Set<String> = []
    private var pendingObserverCompletions: [() -> Void] = []
    private var observerDebounceTask: Task<Void, Never>?
    private var lastForegroundSync = Date.distantPast

    private static let initialHistoryRangeKey = "personalReceiver.v2.initialHistoryRange"
    private static let initialHistoryRangeConfirmedKey =
        "personalReceiver.v2.initialHistoryRangeConfirmed"
    private static let historicalCoverageStartKey = "personalReceiver.v2.historicalCoverageStart"
    private static let completeHistoryKey = "personalReceiver.v2.completeHistory"
    private static let initialDirectBootstrapCompletedKey =
        "personalReceiver.v2.initialDirectBootstrapCompleted"
    private static let recentAuditVersionKey = "personalReceiver.v2.recentHistoryAuditVersion"
    private static let recentAuditDataKey = "personalReceiver.v2.recentHistoryAudit"
    private static let recentAuditErrorKey = "personalReceiver.v2.recentHistoryAuditError"
    private static let recentAuditVersion = "30-days-sleep-workout-activity-v1"
    private static let recentDomainRepairVersionKey =
        "personalReceiver.v2.recentDomainRepairVersion"
    private static let recentDomainRepairVersion = "30-days-semantic-sleep-workout-activity-v2"

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private let priorityQuantityIDs: Set<String> = [
        HKQuantityTypeIdentifier.stepCount.rawValue,
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
        HKQuantityTypeIdentifier.distanceCycling.rawValue,
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.flightsClimbed.rawValue,
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
        HKQuantityTypeIdentifier.appleStandTime.rawValue,
        HKQuantityTypeIdentifier.bodyMass.rawValue,
        HKQuantityTypeIdentifier.heartRate.rawValue,
        HKQuantityTypeIdentifier.restingHeartRate.rawValue,
        HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue,
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
        HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue,
        HKQuantityTypeIdentifier.respiratoryRate.rawValue,
        HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
        HKQuantityTypeIdentifier.bodyTemperature.rawValue,
        HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue,
        HKQuantityTypeIdentifier.vo2Max.rawValue,
        HKQuantityTypeIdentifier.walkingSpeed.rawValue,
        HKQuantityTypeIdentifier.runningSpeed.rawValue,
        HKQuantityTypeIdentifier.runningPower.rawValue,
        HKQuantityTypeIdentifier.runningStrideLength.rawValue,
        HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue,
        HKQuantityTypeIdentifier.runningGroundContactTime.rawValue,
        "HKQuantityTypeIdentifierCyclingPower",
        "HKQuantityTypeIdentifierCyclingCadence",
    ]

    private init() {
        lastSyncDate = UserDefaults.standard.object(forKey: "personalReceiver.lastSyncDate") as? Date
        let storedInitialHistoryRange = UserDefaults.standard.string(forKey: Self.initialHistoryRangeKey)
        if let value = storedInitialHistoryRange,
           let range = InitialHistoryRange(rawValue: value) {
            initialHistoryRange = range
        }
        historicalCoverageStart = UserDefaults.standard.object(
            forKey: Self.historicalCoverageStartKey
        ) as? Date
        hasCompleteHistory = UserDefaults.standard.bool(forKey: Self.completeHistoryKey)
        isInitialDirectBootstrapComplete = UserDefaults.standard.bool(
            forKey: Self.initialDirectBootstrapCompletedKey
        )
        isInitialHistoryRangeConfirmed = UserDefaults.standard.bool(
            forKey: Self.initialHistoryRangeConfirmedKey
        ) || storedInitialHistoryRange != nil || hasCompleteHistory || isInitialDirectBootstrapComplete
        refreshHistoricalSyncMessage()
    }

    var currentConfig: ReceiverConfig { ReceiverConfig.load() }

    var needsHistoricalBackfill: Bool {
        guard !hasCompleteHistory else { return false }
        guard let desiredStart = initialHistoryRange.startDate(relativeTo: Date()) else { return true }
        return historicalCoverageStart.map { desiredStart < $0 } ?? true
    }

    func setInitialHistoryRange(_ range: InitialHistoryRange) {
        initialHistoryRange = range
        UserDefaults.standard.set(range.rawValue, forKey: Self.initialHistoryRangeKey)
        refreshHistoricalSyncMessage()
    }

    func startConfirmedInitialSync() async {
        isInitialHistoryRangeConfirmed = true
        UserDefaults.standard.set(
            true,
            forKey: Self.initialHistoryRangeConfirmedKey
        )
        await syncIncrementalEncrypted(allowHistoricalBackfill: true)
    }

    private var quantityDescriptors: [QuantityTypeDescriptor] {
        HealthDataTypes.allQuantityTypes.filter { priorityQuantityIDs.contains($0.id) && $0.hkType != nil }
    }

    private var readTypes: Set<HKObjectType> {
        var types = Set(quantityDescriptors.compactMap(\.hkType) as [HKObjectType])
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKObjectType.activitySummaryType())
        return types
    }

    func prepare() async {
        isV2Paired = await HealthV2PairingService.shared.isPaired
        if isV2Paired {
            receiverStatusMessage = "已完成安全配对"
            let cloud = CloudStorageConfig.load()
            if cloud.isConfigured, cloud.provider == .s3 {
                do {
                    try await HealthV2PairingService.shared.provisionCloudStorage(
                        config: cloud,
                        credentials: CloudStorageCredentials.load(for: .s3),
                        fallback: currentConfig
                    )
                    let loaded = try await HealthV2PairingService.shared.load()
                    _ = try await v2Collector.reconcileCloudReceipts(
                        config: cloud,
                        credentials: CloudStorageCredentials.load(for: .s3),
                        pairing: loaded.material
                    )
                    cloudStatusMessage = "Receiver 已接管 S3 密文拉取"
                } catch {
                    cloudStatusMessage = "等待与 Receiver 同网后自动下发云配置"
                }
            }
        }
        pendingBatches = await queue.count() + ((try? await v2Collector.pendingBatchCount()) ?? 0)
        await refreshInitialDirectProgress()
        await refreshCloudStatus()
        if UserDefaults.standard.bool(forKey: "personalReceiver.healthPermissionRequested") {
            startObservers()
        }
        if CloudStorageConfig.load().isConfigured {
            statusMessage = pendingBatches > 0 ? "有 \(pendingBatches) 个批次等待上传" : "已就绪"
        }
        await runRecentHistoryAuditIfNeeded()
    }

    private func runRecentHistoryAuditIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: "personalReceiver.healthPermissionRequested"),
              UserDefaults.standard.string(forKey: Self.recentAuditVersionKey)
                != Self.recentAuditVersion else { return }
        do {
            let audit = try await v2Collector.auditRecentHistory(days: 30)
            let data = try JSONEncoder().encode(audit)
            UserDefaults.standard.set(data, forKey: Self.recentAuditDataKey)
            UserDefaults.standard.set(Self.recentAuditVersion, forKey: Self.recentAuditVersionKey)
            UserDefaults.standard.removeObject(forKey: Self.recentAuditErrorKey)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: Self.recentAuditErrorKey)
        }
    }

    func saveAndTestCloud(
        config: CloudStorageConfig,
        credentials: CloudStorageCredentials
    ) async {
        guard !isTestingCloud else { return }
        isTestingCloud = true
        errorMessage = nil
        cloudStatusMessage = "正在测试…"
        defer { isTestingCloud = false }
        do {
            let message = try await cloudTransport.test(config: config, credentials: credentials)
            try config.save(credentials: credentials)
            if isV2Paired, config.provider == .s3 {
                cloudStatusMessage = "云端已连通，正在安全下发给 Receiver…"
                try await HealthV2PairingService.shared.provisionCloudStorage(
                    config: config,
                    credentials: credentials,
                    fallback: currentConfig
                )
            }
            cloudProviderName = config.provider.displayName
            cloudStatusMessage = isV2Paired && config.provider == .s3
                ? "\(message)；Receiver 已接管云端拉取"
                : message
            await refreshCloudStatus()
        } catch {
            cloudStatusMessage = "连接失败"
            errorMessage = error.localizedDescription
        }
    }

    func refreshCloudStatus() async {
        let config = CloudStorageConfig.load()
        cloudProviderName = config.isConfigured ? config.provider.displayName : "未配置"
        guard config.isConfigured else {
            cloudStatusMessage = "尚未配置"
            awaitingCloudUpload = 0
            awaitingCloudPacks = 0
            awaitingReceiver = 0
            return
        }
        let counts = try? await v2Collector.outboxCounts(provider: config.provider)
        awaitingCloudUpload = counts?.awaitingUpload ?? 0
        awaitingCloudPacks = counts?.awaitingUploadPacks ?? 0
        awaitingReceiver = counts?.awaitingReceiver ?? 0
        pendingBatches = counts?.total ?? pendingBatches
        if cloudStatusMessage == "尚未配置" {
            cloudStatusMessage = "已配置"
        }
        if !isInitialDirectBootstrapComplete {
            cloudStatusMessage = "首次历史走局域网直传；云端留给后续增量"
        }
    }

    func pairEncryptedSync() async {
        guard !isSyncing else { return }
        guard currentConfig.isConfigured else {
            errorMessage = "请先在接收端面板生成一次性配对码，再填写 Receiver 地址和配对码。"
            statusMessage = "等待配置首次配对 Receiver"
            return
        }
        isSyncing = true
        errorMessage = nil
        statusMessage = "正在建立端到端加密配对…"
        defer { isSyncing = false }
        do {
            _ = try await HealthV2PairingService.shared.pair(config: currentConfig)
            try ReceiverConfig.clearPairingCode()
            isV2Paired = true
            await provisionSavedCloudIfNeeded()
            statusMessage = "端到端加密配对成功"
        } catch {
            isV2Paired = false
            errorMessage = error.localizedDescription
            statusMessage = "加密配对失败"
        }
    }

    func saveAndPair(localURL: String, remoteURL: String, pairingCode: String) async {
        errorMessage = nil
        receiverStatusMessage = "正在配对…"
        let config = ReceiverConfig(localURL: localURL, remoteURL: remoteURL, pairingCode: pairingCode)
        do {
            try config.save()
            statusMessage = "正在交换设备密钥…"
            _ = try await HealthV2PairingService.shared.pair(config: config)
            try ReceiverConfig.clearPairingCode()
            isV2Paired = true
            await provisionSavedCloudIfNeeded()
            statusMessage = "端到端加密配对成功"
            receiverStatusMessage = "已配对；一次性配对码已从手机删除"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "加密配对失败"
            receiverStatusMessage = error.localizedDescription
        }
    }

    func pairNearby(_ receiver: NearbyReceiver) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        receiverStatusMessage = "正在向 \(receiver.name) 发起请求…"
        statusMessage = "正在进行局域网安全配对…"
        do {
            _ = try await HealthV2PairingService.shared.pairNearby(
                baseURL: receiver.baseURL
            ) { [weak self] message in
                await MainActor.run {
                    self?.receiverStatusMessage = message
                    self?.statusMessage = message
                }
            }
            try ReceiverConfig.clearPairingCode()
            isV2Paired = true
            await provisionSavedCloudIfNeeded()
            statusMessage = "配对成功；请先选择首次同步的历史范围"
            receiverStatusMessage = "已与 \(receiver.name) 完成安全配对"
        } catch is CancellationError {
            receiverStatusMessage = "配对已取消"
            statusMessage = "配对已取消"
        } catch {
            errorMessage = error.localizedDescription
            receiverStatusMessage = error.localizedDescription
            statusMessage = "局域网配对失败"
        }
        isSyncing = false
    }

    private func provisionSavedCloudIfNeeded() async {
        let cloud = CloudStorageConfig.load()
        guard cloud.isConfigured, cloud.provider == .s3 else { return }
        do {
            try await HealthV2PairingService.shared.provisionCloudStorage(
                config: cloud,
                credentials: CloudStorageCredentials.load(for: .s3),
                fallback: currentConfig
            )
            cloudStatusMessage = "Receiver 已接管 S3 密文拉取"
        } catch {
            cloudStatusMessage = "已配对；与 Receiver 同网后会自动下发云配置"
        }
    }

    func requestHealthAuthorization() async {
        errorMessage = nil
        do {
            guard healthKit.isAvailable else { throw HKError(.errorHealthDataUnavailable) }
            try await healthKit.requestPermissions(for: readTypes)
            UserDefaults.standard.set(true, forKey: "personalReceiver.healthPermissionRequested")
            startObservers()
            statusMessage = "健康权限已请求"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "健康授权失败"
        }
    }

    func syncOnForegroundIfNeeded() async {
        guard CloudStorageConfig.load().isConfigured,
              UserDefaults.standard.bool(forKey: "personalReceiver.healthPermissionRequested"),
              Date().timeIntervalSince(lastForegroundSync) > 15 * 60 else { return }
        lastForegroundSync = Date()
        if isV2Paired {
            await syncIncrementalEncrypted(allowHistoricalBackfill: false)
        } else {
            statusMessage = "请先在设置中完成端到端加密配对"
        }
    }

    func performBackgroundRefresh() async -> Bool {
        guard CloudStorageConfig.load().isConfigured,
              isV2Paired,
              UserDefaults.standard.bool(forKey: "personalReceiver.healthPermissionRequested")
        else { return false }
        await syncIncrementalEncrypted(allowHistoricalBackfill: false)
        return errorMessage == nil
    }

    func syncIncrementalEncrypted(
        changedTypeIdentifiers: Set<String>? = nil,
        allowHistoricalBackfill: Bool = true
    ) async {
        if !isInitialDirectBootstrapComplete && !isInitialHistoryRangeConfirmed {
            statusMessage = "请先确认首次同步的历史范围"
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        uploadedRecords = 0
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let credentials = try await HealthV2PairingService.shared.load()
            if allowHistoricalBackfill, changedTypeIdentifiers == nil {
                try await repairRecentDomainHistoryIfNeeded(credentials: credentials)
            }
            if !UserDefaults.standard.bool(forKey: Self.initialDirectBootstrapCompletedKey) {
                try await performInitialDirectBootstrap(
                    credentials: credentials,
                    changedTypeIdentifiers: changedTypeIdentifiers,
                    allowHistoricalBackfill: allowHistoricalBackfill
                )
                return
            }
            let cloudConfig = CloudStorageConfig.load()
            var cloudDeferredUntil: Date?
            statusMessage = "正在发送本地待上传密文…"
            if cloudConfig.isConfigured, cloudConfig.provider != .directDebug {
                let cloudCredentials = CloudStorageCredentials.load(for: cloudConfig.provider)
                let result = try await v2Collector.flushCloud(
                    config: cloudConfig,
                    credentials: cloudCredentials,
                    pairing: credentials.material
                )
                cloudDeferredUntil = result.deferredUntil
                lastEndpoint = cloudConfig.provider.displayName
            } else {
                let uploadResult = try await v2Collector.flush(config: currentConfig)
                if let endpoint = uploadResult.endpoint { lastEndpoint = endpoint.absoluteString }
            }

            let bootstrapCutoff = Date()
            statusMessage = "正在增量读取 HealthKit…"
            uploadedRecords += try await v2Collector.collect(
                quantityDescriptors: quantityDescriptors,
                changedTypeIdentifiers: changedTypeIdentifiers,
                bootstrapCutoff: bootstrapCutoff,
                pairing: credentials.material,
                signingPrivateKey: credentials.signingPrivateKey
            )
            pendingBatches = try await v2Collector.pendingBatchCount()
            statusMessage = "正在合并并上传端到端加密批次…"
            if cloudConfig.isConfigured, cloudConfig.provider != .directDebug {
                let cloudCredentials = CloudStorageCredentials.load(for: cloudConfig.provider)
                if cloudDeferredUntil == nil || cloudDeferredUntil! <= Date() {
                    let result = try await v2Collector.flushCloud(
                        config: cloudConfig,
                        credentials: cloudCredentials,
                        pairing: credentials.material
                    )
                    cloudDeferredUntil = result.deferredUntil
                }
                lastEndpoint = cloudConfig.provider.displayName
            } else {
                let uploadResult = try await v2Collector.flush(config: currentConfig)
                if let endpoint = uploadResult.endpoint { lastEndpoint = endpoint.absoluteString }
            }
            pendingBatches = try await v2Collector.pendingBatchCount()
            await refreshCloudStatus()
            if let retryAt = cloudDeferredUntil, retryAt > Date() {
                let delay = max(60, retryAt.timeIntervalSinceNow)
                V2BackgroundSyncCoordinator.shared.scheduleNext(earliest: delay)
                cloudStatusMessage = "限流暂停；将在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后续传"
                statusMessage = "健康数据已加密保存在手机；云端限流，\(pendingBatches) 个批次等待自动续传"
                refreshHistoricalSyncMessage()
                return
            }
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "personalReceiver.lastSyncDate")
            statusMessage = needsHistoricalBackfill
                ? "增量同步完成；首次历史回溯尚未完成"
                : "加密同步完成，共处理 \(uploadedRecords) 条记录"
            refreshHistoricalSyncMessage()
        } catch is CancellationError {
            statusMessage = "同步已取消"
        } catch {
            pendingBatches = (try? await v2Collector.pendingBatchCount()) ?? pendingBatches
            errorMessage = error.localizedDescription
            statusMessage = "加密同步未完成，密文已保留等待重试"
        }
        if !pendingObserverTypes.isEmpty {
            scheduleObserverDrain(after: 1)
        }
    }

    private func performInitialDirectBootstrap(
        credentials: (material: HealthPairingMaterial, signingPrivateKey: Data),
        changedTypeIdentifiers: Set<String>?,
        allowHistoricalBackfill: Bool
    ) async throws {
        let directURLs = await HealthV2PairingService.shared.directReceiverBaseURLs(
            fallback: currentConfig
        )
        guard !directURLs.isEmpty else {
            throw HealthV2PairingError.noEndpoint
        }

        cloudStatusMessage = "首次历史走局域网直传；云端留给后续增量"
        await refreshInitialDirectProgress()
        pendingBatches = try await v2Collector.pendingBatchCount()
        if pendingBatches > 0 {
            let estimatedPacks = max(1, Int(ceil(Double(pendingBatches) / 64.0)))
            statusMessage = "首次同步：通过局域网直传约 \(estimatedPacks) 个密文包…"
            let upload = try await v2Collector.flushDirect(
                baseURLs: directURLs,
                pairing: credentials.material,
                progress: initialDirectProgressHandler()
            )
            if let endpoint = upload.endpoint { lastEndpoint = endpoint.absoluteString }
            pendingBatches = try await v2Collector.pendingBatchCount()
        }

        let bootstrapCutoff = Date()
        if allowHistoricalBackfill,
           changedTypeIdentifiers == nil,
           needsHistoricalBackfill {
            uploadedRecords += try await runHistoricalMonthBackfill(
                referenceDate: bootstrapCutoff,
                directBaseURLs: directURLs,
                pairing: credentials.material,
                signingPrivateKey: credentials.signingPrivateKey
            )
        }

        statusMessage = "首次同步：读取最新 HealthKit 增量…"
        uploadedRecords += try await v2Collector.collect(
            quantityDescriptors: quantityDescriptors,
            changedTypeIdentifiers: changedTypeIdentifiers,
            bootstrapCutoff: bootstrapCutoff,
            pairing: credentials.material,
            signingPrivateKey: credentials.signingPrivateKey
        )
        pendingBatches = try await v2Collector.pendingBatchCount()
        if pendingBatches > 0 {
            await refreshInitialDirectProgress()
            statusMessage = "首次同步：发送最后一批局域网密文包…"
            let upload = try await v2Collector.flushDirect(
                baseURLs: directURLs,
                pairing: credentials.material,
                progress: initialDirectProgressHandler()
            )
            if let endpoint = upload.endpoint { lastEndpoint = endpoint.absoluteString }
        }

        pendingBatches = try await v2Collector.pendingBatchCount()
        await refreshCloudStatus()
        if pendingBatches == 0 && !needsHistoricalBackfill {
            UserDefaults.standard.set(true, forKey: Self.initialDirectBootstrapCompletedKey)
            isInitialDirectBootstrapComplete = true
            initialDirectCompletedBatches = initialDirectTotalBatches
            initialDirectRemainingBatches = 0
            initialDirectRemainingPacks = 0
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "personalReceiver.lastSyncDate")
            statusMessage = "首次历史直传完成；后续增量将通过云存储同步"
        } else if needsHistoricalBackfill {
            statusMessage = "局域网密文已同步；打开 App 后可继续首次历史回溯"
        } else {
            statusMessage = "首次直传尚有 \(pendingBatches) 个批次，稍后将自动续传"
        }
        refreshHistoricalSyncMessage()
    }

    private func runHistoricalMonthBackfill(
        referenceDate: Date,
        directBaseURLs: [URL],
        pairing: HealthPairingMaterial,
        signingPrivateKey: Data
    ) async throws -> Int {
        let includesAllHistory = initialHistoryRange == .all
        let desiredStart: Date
        if let configuredStart = initialHistoryRange.startDate(relativeTo: referenceDate) {
            desiredStart = configuredStart
        } else if let earliest = try await v2Collector.earliestAvailableDate(
            quantityDescriptors: quantityDescriptors
        ) {
            desiredStart = earliest
        } else {
            markAllHistoryCompleted()
            return 0
        }

        var windowEnd = historicalCoverageStart ?? referenceDate
        guard desiredStart < windowEnd else {
            if includesAllHistory { markAllHistoryCompleted() }
            return 0
        }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        let groupFormatter = DateFormatter()
        groupFormatter.calendar = calendar
        groupFormatter.locale = Locale(identifier: "en_US_POSIX")
        groupFormatter.dateFormat = "yyyy-MM"
        var total = 0

        while desiredStart < windowEnd {
            try Task.checkCancellation()
            let probe = windowEnd.addingTimeInterval(-0.001)
            let naturalMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: probe)
            ) ?? desiredStart
            let windowStart = max(desiredStart, naturalMonthStart)
            let monthLabel = formatter.string(from: probe)
            let relayGroup = "history/\(groupFormatter.string(from: probe))"
            let beforeMonthCount = total

            statusMessage = "首次历史回溯：\(monthLabel)"
            historicalSyncMessage = "正在准备 \(monthLabel) 数据…"
            total += try await v2Collector.collectHistory(
                quantityDescriptors: quantityDescriptors,
                from: windowStart,
                until: windowEnd,
                relayGroup: relayGroup,
                pairing: pairing,
                signingPrivateKey: signingPrivateKey
            ) { [weak self] label, monthCount in
                await MainActor.run {
                    self?.uploadedRecords = beforeMonthCount + monthCount
                    self?.historicalSyncMessage = "\(monthLabel)：正在读取\(label)，已整理 \(monthCount) 条"
                    self?.statusMessage = "首次历史回溯：\(monthLabel) · \(label)"
                }
            }
            recordHistoricalCoverage(start: windowStart)
            historicalSyncMessage = "\(monthLabel) 已整理，正在合并密文 Part…"

            await refreshInitialDirectProgress()
            let upload = try await v2Collector.flushDirect(
                baseURLs: directBaseURLs,
                pairing: pairing,
                progress: initialDirectProgressHandler()
            )
            if let endpoint = upload.endpoint { lastEndpoint = endpoint.absoluteString }
            historicalSyncMessage = "已完成 \(monthLabel)，继续回溯更早月份…"
            windowEnd = windowStart
        }

        if includesAllHistory { markAllHistoryCompleted() }
        return total
    }

    private func markAllHistoryCompleted() {
            hasCompleteHistory = true
            historicalCoverageStart = nil
            UserDefaults.standard.set(true, forKey: Self.completeHistoryKey)
            UserDefaults.standard.removeObject(forKey: Self.historicalCoverageStartKey)
        refreshHistoricalSyncMessage()
    }

    private func recordHistoricalCoverage(start: Date) {
        historicalCoverageStart = min(historicalCoverageStart ?? start, start)
        UserDefaults.standard.set(historicalCoverageStart, forKey: Self.historicalCoverageStartKey)
        refreshHistoricalSyncMessage()
    }

    private func refreshInitialDirectProgress() async {
        guard let snapshot = try? await v2Collector.initialDirectProgressSnapshot() else { return }
        initialDirectTotalBatches = snapshot.totalBatches
        initialDirectCompletedBatches = snapshot.completedBatches
        initialDirectRemainingBatches = snapshot.remainingBatches
        initialDirectRemainingPacks = snapshot.remainingPacks
    }

    /// Repairs the legacy completion bug without repeating the very large
    /// quantity history. Old builds inferred global completion from quantity
    /// anchors, even though sleep, workouts/routes and activity summaries use
    /// independent streams. This bounded repair is idempotent at the Receiver.
    private func repairRecentDomainHistoryIfNeeded(
        credentials: (material: HealthPairingMaterial, signingPrivateKey: Data)
    ) async throws {
        guard UserDefaults.standard.string(forKey: Self.recentDomainRepairVersionKey)
                != Self.recentDomainRepairVersion else { return }
        let directURLs = await HealthV2PairingService.shared.directReceiverBaseURLs(
            fallback: currentConfig
        )
        guard !directURLs.isEmpty else { return }

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: endDate)
            ?? endDate.addingTimeInterval(-30 * 86_400)
        statusMessage = "正在修复近 30 天睡眠、锻炼与活动数据…"
        uploadedRecords += try await v2Collector.collectDomainHistory(
            from: startDate,
            until: endDate,
            relayGroup: "repair/recent-domains-v1",
            pairing: credentials.material,
            signingPrivateKey: credentials.signingPrivateKey
        ) { [weak self] label, count in
            await MainActor.run {
                self?.statusMessage = "近 30 天数据修复：\(label) · \(count) 条"
            }
        }
        let upload = try await v2Collector.flushDirect(
            baseURLs: directURLs,
            pairing: credentials.material,
            progress: initialDirectProgressHandler()
        )
        if let endpoint = upload.endpoint { lastEndpoint = endpoint.absoluteString }
        guard try await v2Collector.pendingBatchCount() == 0 else { return }
        UserDefaults.standard.set(
            Self.recentDomainRepairVersion,
            forKey: Self.recentDomainRepairVersionKey
        )
        statusMessage = "近 30 天睡眠、锻炼与活动数据已修复"
    }

    private func initialDirectProgressHandler()
        -> @Sendable (Int, Int, Int, Int) async -> Void {
        let baselineCompleted = initialDirectCompletedBatches
        let baselineRemaining = initialDirectRemainingBatches
        let baselinePacks = initialDirectRemainingPacks
        return { [weak self] completed, _, completedPacks, _ in
            await MainActor.run {
                guard let self else { return }
                self.initialDirectCompletedBatches = min(
                    self.initialDirectTotalBatches,
                    baselineCompleted + completed
                )
                self.initialDirectRemainingBatches = max(0, baselineRemaining - completed)
                self.initialDirectRemainingPacks = max(0, baselinePacks - completedPacks)
                let percent = self.initialDirectTotalBatches > 0
                    ? Int(
                        Double(self.initialDirectCompletedBatches)
                            / Double(self.initialDirectTotalBatches) * 100
                    )
                    : 0
                self.statusMessage =
                    "首次局域网直传 \(percent)% · 剩余 \(self.initialDirectRemainingPacks) 个密文包"
            }
        }
    }

    private func refreshHistoricalSyncMessage() {
        if hasCompleteHistory {
            historicalSyncMessage = "全部可用历史已回溯"
        } else if let start = historicalCoverageStart {
            historicalSyncMessage = "已覆盖 \(start.formatted(date: .abbreviated, time: .omitted)) 至今"
        } else {
            historicalSyncMessage = "尚未执行首次历史回溯"
        }
    }

    func syncRecent(days: Int = 3) async {
        guard !isSyncing else { return }
        let config = currentConfig
        guard config.isConfigured else {
            errorMessage = SyncError.notConfigured.localizedDescription
            return
        }
        isSyncing = true
        uploadedRecords = 0
        errorMessage = nil
        defer { isSyncing = false }

        do {
            statusMessage = "正在重试待上传批次…"
            try await flushQueue(config: config)

            let since = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: Date())!
            statusMessage = "正在读取健康指标…"
            for descriptor in quantityDescriptors {
                try Task.checkCancellation()
                let samples = try await healthKit.fetchQuantitySamples(
                    typeID: descriptor.hkIdentifier,
                    unit: descriptor.unit,
                    from: since
                )
                let rows = samples.map { sample in
                    HBQuantityRow(
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
                }
                try await upload(rows, endpoint: "api/v1/healthbeat/quantity-samples", config: config)
            }

            statusMessage = "正在读取睡眠…"
            let sleepSamples = try await healthKit.fetchCategorySamples(typeID: .sleepAnalysis, from: since)
            let sleepDescriptor = HealthDataTypes.categoryDescriptor(for: HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
            let sleepRows = sleepSamples.map { sample in
                HBCategoryRow(
                    uuid: sample.uuid.uuidString,
                    type: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                    value: sample.value,
                    value_label: sleepDescriptor?.valueLabels[sample.value],
                    start_date: Self.timestamp(sample.startDate),
                    end_date: Self.timestamp(sample.endDate),
                    source_name: sample.sourceDisplayName,
                    source_bundle_id: sample.sourceBundleID,
                    device_name: sample.deviceName,
                    metadata: Self.metadataJSON(sample.metadata)
                )
            }
            try await upload(sleepRows, endpoint: "api/v1/healthbeat/category-samples", config: config)

            statusMessage = "正在读取锻炼…"
            let workouts = try await healthKit.fetchWorkouts(from: since)
            let workoutRows = workouts.map { workout in
                HBWorkoutRow(
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
            }
            try await upload(workoutRows, endpoint: "api/v1/healthbeat/workouts", config: config)

            statusMessage = "正在读取锻炼路线…"
            for workout in workouts {
                let routes = try await healthKit.fetchWorkoutRoutes(for: workout)
                var routeRows: [HBWorkoutRouteRow] = []
                for route in routes {
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
                    let json = try JSONSerialization.data(withJSONObject: locationObjects)
                    routeRows.append(HBWorkoutRouteRow(
                        uuid: route.uuid.uuidString,
                        workout_uuid: workout.uuid.uuidString,
                        start_date: Self.timestamp(route.startDate),
                        location_count: locations.count,
                        locations_json: String(data: json, encoding: .utf8)
                    ))
                }
                try await upload(routeRows, endpoint: "api/v1/healthbeat/workout-routes", config: config)
            }

            statusMessage = "正在读取活动圆环…"
            let summaries = try await healthKit.fetchActivitySummaries(from: since, until: Date())
            let calendar = Calendar.current
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let activityRows = summaries.compactMap { summary -> HBActivitySummaryRow? in
                guard let summaryDate = calendar.date(from: summary.dateComponents(for: calendar)) else { return nil }
                return HBActivitySummaryRow(
                    date: dayFormatter.string(from: summaryDate),
                    active_energy_burned: summary.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                    active_energy_burned_goal: summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()),
                    exercise_time_minutes: summary.appleExerciseTime.doubleValue(for: .minute()),
                    exercise_time_goal_minutes: summary.appleExerciseTimeGoal.doubleValue(for: .minute()),
                    stand_hours: Int(summary.appleStandHours.doubleValue(for: .count())),
                    stand_hours_goal: Int(summary.appleStandHoursGoal.doubleValue(for: .count()))
                )
            }
            try await upload(activityRows, endpoint: "api/v1/healthbeat/activity-summaries", config: config)

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "personalReceiver.lastSyncDate")
            pendingBatches = await queue.count()
            statusMessage = "同步完成，共处理 \(uploadedRecords) 条记录"
        } catch is CancellationError {
            statusMessage = "同步已取消"
        } catch {
            pendingBatches = await queue.count()
            errorMessage = error.localizedDescription
            statusMessage = "同步未完成，数据已保留等待重试"
        }
    }

    private func upload<T: Encodable>(_ records: [T], endpoint: String, config: ReceiverConfig) async throws {
        guard !records.isEmpty else { return }
        for batch in records.chunkedForUpload(size: 400) {
            let body = try encoder.encode(WireEnvelope(records: batch))
            let job = try await queue.enqueue(endpoint: endpoint, body: body)
            let selected = try await client.send(job, config: config)
            try await queue.remove(job)
            uploadedRecords += batch.count
            lastEndpoint = selected.absoluteString
            pendingBatches = await queue.count()
        }
    }

    private func flushQueue(config: ReceiverConfig) async throws {
        for job in await queue.pending() {
            let selected = try await client.send(job, config: config)
            try await queue.remove(job)
            lastEndpoint = selected.absoluteString
        }
        pendingBatches = await queue.count()
    }

    private func startObservers() {
        guard !observersStarted else { return }
        observersStarted = true
        for case let sampleType as HKSampleType in readTypes {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                Task { @MainActor in
                    guard let self else {
                        completion()
                        return
                    }
                    if self.isV2Paired, CloudStorageConfig.load().isConfigured {
                        self.enqueueObserverChange(typeIdentifier: sampleType.identifier, completion: completion)
                    } else {
                        completion()
                    }
                }
            }
            healthKit.store.execute(query)
            observerQueries.append(query)
            healthKit.store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
        }
    }

    private func enqueueObserverChange(typeIdentifier: String, completion: @escaping () -> Void) {
        pendingObserverTypes.insert(typeIdentifier)
        pendingObserverCompletions.append(completion)
        scheduleObserverDrain(after: 2)
    }

    private func scheduleObserverDrain(after seconds: TimeInterval) {
        observerDebounceTask?.cancel()
        observerDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self else { return }
            if self.isSyncing {
                self.scheduleObserverDrain(after: 3)
                return
            }
            let types = self.pendingObserverTypes
            let completions = self.pendingObserverCompletions
            self.pendingObserverTypes.removeAll()
            self.pendingObserverCompletions.removeAll()
            await self.syncIncrementalEncrypted(
                changedTypeIdentifiers: types,
                allowHistoricalBackfill: false
            )
            completions.forEach { $0() }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.healthSync.string(from: date)
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

private extension ISO8601DateFormatter {
    static let healthSync: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private extension Array {
    func chunkedForUpload(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
