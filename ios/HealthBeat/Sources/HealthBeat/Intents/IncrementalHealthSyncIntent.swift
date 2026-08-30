import AppIntents

struct IncrementalHealthSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "立即增量同步"
    static var description = IntentDescription(
        "读取 Apple Health 的最新变化，加密保存并提交后台上传。不会打开 App，也不会执行历史回溯。",
        categoryName: "健康同步"
    )

    // Keep iOS 17.6 compatibility. The default false value allows Shortcuts to
    // run the intent without bringing the app UI to the foreground.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PersonalHealthSyncService.shared
            .performShortcutIncrementalSync()
        if result.wasAlreadyRunning {
            return .result(value: "已有同步任务正在运行；已安排任务结束后再检查一次增量。")
        }
        if result.immediatelyUploadedBatches > 0 {
            let tail = result.uploadScheduled
                ? "其余批次已进入 iOS 后台队列。"
                : "Receiver 通常会在约 30 秒内完成入库。"
            return .result(
                value: "已加密处理 \(result.records) 条新记录，并立即上传 \(result.immediatelyUploadedBatches) 个批次。\(tail)"
            )
        }
        if result.records == 0 && result.pendingBatches == 0 {
            return .result(value: "增量检查完成，没有发现新的健康记录。")
        }
        if result.uploadScheduled {
            return .result(
                value: "已加密处理 \(result.records) 条新记录；即时上传未完成，已转入 iOS 后台队列。"
            )
        }
        return .result(
            value: "已加密处理 \(result.records) 条新记录，当前有 \(result.pendingBatches) 个批次安全保存在手机，等待自动重试。"
        )
    }
}

struct HealthTrackerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IncrementalHealthSyncIntent(),
            phrases: [
                "用\(.applicationName)同步健康数据",
                "让\(.applicationName)立即同步",
                "运行\(.applicationName)健康同步",
            ],
            shortTitle: "立即增量同步",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
