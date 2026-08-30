import AppIntents

struct IncrementalHealthSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "立即增量同步"
    static var description = IntentDescription(
        "向健康同步 App 提交一次增量同步请求。具体读取、加密和上传由 App 在系统允许时执行。",
        categoryName: "健康同步"
    )

    // Keep iOS 17.6 compatibility. The default false value allows Shortcuts to
    // run the intent without bringing the app UI to the foreground.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try PersonalHealthSyncService.shared.requestShortcutIncrementalSync()
        if result.syncWasRunning {
            return .result(value: "同步请求已记录；当前任务结束后由 App 继续处理。")
        }
        if result.wasAlreadyPending {
            return .result(value: "同步请求已更新；App 会合并处理，不会重复入库。")
        }
        return .result(value: "同步请求已提交；App 将在 iOS 允许时读取、加密并上传增量数据。")
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
