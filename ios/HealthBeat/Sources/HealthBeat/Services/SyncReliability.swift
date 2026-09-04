import Foundation
import UserNotifications

enum HealthSyncTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case healthObserver = "health_observer"
    case backgroundRefresh = "background_refresh"
    case foreground = "foreground"
    case shortcut = "shortcut"
    case workoutShortcut = "workout_shortcut"
    case manual = "manual"
    case protectedDataAvailable = "protected_data_available"

    var displayName: String {
        switch self {
        case .healthObserver: return "健康数据变化"
        case .backgroundRefresh: return "系统后台刷新"
        case .foreground: return "进入前台补漏"
        case .shortcut: return "快捷指令"
        case .workoutShortcut: return "训练结束快捷指令"
        case .manual: return "手动同步"
        case .protectedDataAvailable: return "解锁后续传"
        }
    }
}

enum HealthSyncAttemptStage: String, Codable, Sendable {
    case queued
    case merged
    case waitingForUnlock = "waiting_for_unlock"
    case collecting
    case encryptedLocally = "encrypted_locally"
    case handedToBackground = "handed_to_background"
    case completed
    case failed

    var displayName: String {
        switch self {
        case .queued: return "已记录"
        case .merged: return "已合并等待"
        case .waitingForUnlock: return "等待解锁"
        case .collecting: return "读取健康数据"
        case .encryptedLocally: return "已加密保存"
        case .handedToBackground: return "已交给后台上传"
        case .completed: return "已完成"
        case .failed: return "等待重试"
        }
    }
}

struct HealthSyncAttempt: Codable, Identifiable, Sendable {
    let id: UUID
    let trigger: HealthSyncTrigger
    let requestedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var stage: HealthSyncAttemptStage
    var stageTimestamps: [String: Date]?
    var appState: String
    var protectedDataAvailable: Bool
    var lowPowerMode: Bool
    var dirtyTypeCount: Int
    var recordsCollected: Int
    var scheduledBatches: Int
    var pendingBatches: Int
    var errorDomain: String?
    var errorCode: Int?
    var errorDescription: String?
}

actor HealthSyncAttemptJournal {
    static let shared = HealthSyncAttemptJournal()

    private let fileURL: URL
    private var records: [HealthSyncAttempt]
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PersonalHealthSync/V2/Reliability", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appending(path: "sync-attempts.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()
        records = ((try? Data(contentsOf: fileURL)).flatMap {
            try? decoder.decode([HealthSyncAttempt].self, from: $0)
        } ?? []).map { record in
            var recovered = record
            if recovered.finishedAt == nil,
               now.timeIntervalSince(recovered.requestedAt) >= 15 * 60 {
                recovered.stage = .failed
                recovered.finishedAt = now
                var timestamps = recovered.stageTimestamps ?? [:]
                timestamps[HealthSyncAttemptStage.failed.rawValue] = now
                recovered.stageTimestamps = timestamps
                recovered.errorDomain = "HealthTracker.SyncLease"
                recovered.errorCode = 1
                recovered.errorDescription = "同步被系统中断，任务已自动重新排队"
            }
            return recovered
        }
        if let data = try? encoder.encode(records) {
            try? data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    func begin(
        trigger: HealthSyncTrigger,
        appState: String,
        protectedDataAvailable: Bool,
        lowPowerMode: Bool,
        dirtyTypeCount: Int
    ) -> UUID {
        let id = UUID()
        records.append(HealthSyncAttempt(
            id: id,
            trigger: trigger,
            requestedAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            stage: .queued,
            stageTimestamps: [HealthSyncAttemptStage.queued.rawValue: Date()],
            appState: appState,
            protectedDataAvailable: protectedDataAvailable,
            lowPowerMode: lowPowerMode,
            dirtyTypeCount: dirtyTypeCount,
            recordsCollected: 0,
            scheduledBatches: 0,
            pendingBatches: 0,
            errorDomain: nil,
            errorCode: nil,
            errorDescription: nil
        ))
        trimAndSave()
        return id
    }

    func mark(
        _ id: UUID,
        stage: HealthSyncAttemptStage,
        recordsCollected: Int? = nil,
        scheduledBatches: Int? = nil,
        pendingBatches: Int? = nil,
        error: Error? = nil,
        finished: Bool = false
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].stage = stage
        var timestamps = records[index].stageTimestamps ?? [:]
        timestamps[stage.rawValue] = Date()
        records[index].stageTimestamps = timestamps
        if records[index].startedAt == nil, stage != .queued { records[index].startedAt = Date() }
        if let recordsCollected { records[index].recordsCollected = recordsCollected }
        if let scheduledBatches { records[index].scheduledBatches = scheduledBatches }
        if let pendingBatches { records[index].pendingBatches = pendingBatches }
        if let error {
            let nsError = error as NSError
            records[index].errorDomain = nsError.domain
            records[index].errorCode = nsError.code
            records[index].errorDescription = error.localizedDescription
        }
        if finished { records[index].finishedAt = Date() }
        trimAndSave()
    }

    func recent(limit: Int = 12) -> [HealthSyncAttempt] {
        Array(records.suffix(max(1, limit)).reversed())
    }

    func exportURL() -> URL { fileURL }

    private func trimAndSave() {
        let cutoff = Date(timeIntervalSinceNow: -14 * 24 * 60 * 60)
        records = Array(records.filter { $0.requestedAt >= cutoff }.suffix(100))
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct DurableHealthSyncWork: Codable, Sendable {
    let id: UUID
    let generation: UInt64
    let requestedAt: Date
    /// Lease start is optional so state written by earlier app versions still decodes.
    let claimedAt: Date?
    let triggers: Set<HealthSyncTrigger>
    let dirtyTypeIdentifiers: Set<String>
    let requiresFullScan: Bool
}

private struct DurableHealthSyncState: Codable {
    var nextGeneration: UInt64 = 1
    var pendingSince: Date?
    var pendingTriggers: Set<HealthSyncTrigger> = []
    var dirtyTypeIdentifiers: Set<String> = []
    var requiresFullScan = false
    var workoutRecheckNotBefore: Date?
    var inFlight: DurableHealthSyncWork?
}

actor DurableHealthSyncCoordinator {
    static let shared = DurableHealthSyncCoordinator()

    private let fileURL: URL
    private var state: DurableHealthSyncState
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PersonalHealthSync/V2/Reliability", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolvedFileURL = base.appending(path: "pending-sync.json")
        fileURL = resolvedFileURL
        var loadedState = (try? Data(contentsOf: resolvedFileURL)).flatMap {
            try? JSONDecoder().decode(DurableHealthSyncState.self, from: $0)
        } ?? DurableHealthSyncState()
        // A process may have been suspended or killed after claiming work. Put
        // it back immediately; HealthKit anchors and stable pack IDs make this safe.
        if let abandoned = loadedState.inFlight {
            loadedState.pendingSince = min(
                loadedState.pendingSince ?? abandoned.requestedAt,
                abandoned.requestedAt
            )
            loadedState.pendingTriggers.formUnion(abandoned.triggers)
            loadedState.dirtyTypeIdentifiers.formUnion(abandoned.dirtyTypeIdentifiers)
            loadedState.requiresFullScan = loadedState.requiresFullScan || abandoned.requiresFullScan
            loadedState.inFlight = nil
        }
        state = loadedState
        if let data = try? JSONEncoder().encode(loadedState) {
            try? data.write(
                to: resolvedFileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    @discardableResult
    func request(
        trigger: HealthSyncTrigger,
        dirtyTypes: Set<String> = [],
        fullScan: Bool = false,
        workoutRecheckAfter: TimeInterval? = nil
    ) -> UInt64 {
        state.pendingSince = state.pendingSince ?? Date()
        state.pendingTriggers.insert(trigger)
        state.dirtyTypeIdentifiers.formUnion(dirtyTypes)
        state.requiresFullScan = state.requiresFullScan || fullScan
        if let workoutRecheckAfter {
            let target = Date(timeIntervalSinceNow: workoutRecheckAfter)
            state.workoutRecheckNotBefore = max(state.workoutRecheckNotBefore ?? .distantPast, target)
        }
        let generation = state.nextGeneration
        state.nextGeneration &+= 1
        save()
        return generation
    }

    func hasPendingWork(now: Date = Date()) -> Bool {
        state.pendingSince != nil || state.inFlight != nil || (state.workoutRecheckNotBefore.map { $0 <= now } ?? false)
    }

    /// iOS can suspend an async task between durable collection and network
    /// handoff without cancelling it. Requeue an expired lease so a later
    /// foreground/background opportunity is not permanently merged into it.
    @discardableResult
    func recoverExpiredLease(now: Date = Date(), maximumAge: TimeInterval = 15 * 60) -> Bool {
        guard let abandoned = state.inFlight else { return false }
        let leaseStartedAt = abandoned.claimedAt ?? abandoned.requestedAt
        guard now.timeIntervalSince(leaseStartedAt) >= maximumAge else { return false }
        state.pendingSince = min(
            state.pendingSince ?? abandoned.requestedAt,
            abandoned.requestedAt
        )
        state.pendingTriggers.formUnion(abandoned.triggers)
        state.dirtyTypeIdentifiers.formUnion(abandoned.dirtyTypeIdentifiers)
        state.requiresFullScan = state.requiresFullScan || abandoned.requiresFullScan
        state.inFlight = nil
        save()
        return true
    }

    func claim(now: Date = Date()) -> DurableHealthSyncWork? {
        if let inFlight = state.inFlight { return inFlight }
        if let due = state.workoutRecheckNotBefore, due <= now {
            state.pendingSince = state.pendingSince ?? due
            state.pendingTriggers.insert(.workoutShortcut)
            state.requiresFullScan = true
            state.workoutRecheckNotBefore = nil
        }
        guard let requestedAt = state.pendingSince else { return nil }
        let work = DurableHealthSyncWork(
            id: UUID(),
            generation: state.nextGeneration,
            requestedAt: requestedAt,
            claimedAt: now,
            triggers: state.pendingTriggers,
            dirtyTypeIdentifiers: state.dirtyTypeIdentifiers,
            requiresFullScan: state.requiresFullScan
        )
        state.nextGeneration &+= 1
        state.pendingSince = nil
        state.pendingTriggers = []
        state.dirtyTypeIdentifiers = []
        state.requiresFullScan = false
        state.inFlight = work
        save()
        return work
    }

    func finish(_ work: DurableHealthSyncWork, success: Bool) {
        guard state.inFlight?.id == work.id else { return }
        state.inFlight = nil
        if !success {
            state.pendingSince = min(state.pendingSince ?? work.requestedAt, work.requestedAt)
            state.pendingTriggers.formUnion(work.triggers)
            state.dirtyTypeIdentifiers.formUnion(work.dirtyTypeIdentifiers)
            state.requiresFullScan = state.requiresFullScan || work.requiresFullScan
        }
        save()
    }

    func nextWorkoutRecheckDate() -> Date? { state.workoutRecheckNotBefore }

    private func save() {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum StaleHealthSyncReminder {
    static let preferenceKey = "personalReceiver.v2.staleReminderEnabled"
    private static let notificationID = "health-sync-stale"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }

    static func setEnabled(_ enabled: Bool, lastSuccessfulSync: Date?) async -> Bool {
        if enabled {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            guard granted else { return false }
            UserDefaults.standard.set(true, forKey: preferenceKey)
            schedule(after: lastSuccessfulSync)
            return true
        }
        UserDefaults.standard.set(false, forKey: preferenceKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        return true
    }

    static func schedule(after lastSuccessfulSync: Date?) {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        let content = UNMutableNotificationContent()
        content.title = "健康数据还没有同步"
        content.body = "已超过 24 小时没有完成同步。点此打开 App，系统会自动补传。"
        content.sound = .default
        let elapsed = lastSuccessfulSync.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(60, 24 * 60 * 60 - elapsed)
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        center.add(request)
    }
}
