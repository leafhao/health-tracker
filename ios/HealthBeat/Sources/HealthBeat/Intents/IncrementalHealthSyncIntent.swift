import AppIntents

struct IncrementalHealthSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "立即增量同步"
    static var description = IntentDescription(
        "立即读取健康增量、生成加密包，并把上传交给 iOS 后台传输。",
        categoryName: "健康同步"
    )

    // Keep iOS 17.6 compatibility. The default false value allows Shortcuts to
    // run the intent without bringing the app UI to the foreground.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PersonalHealthSyncService.shared.requestShortcutIncrementalSync()
        if result.syncWasRunning {
            return .result(value: "同步请求已记录；当前任务结束后由 App 继续处理。")
        }
        return .result(value: result.message)
    }
}

struct WorkoutEndedHealthSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "训练结束后同步"
    static var description = IntentDescription(
        "立即同步一次，并在 10 分钟后复查训练、心率恢复和路线等稍晚写入的数据。",
        categoryName: "健康同步"
    )

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await PersonalHealthSyncService.shared.requestWorkoutEndedSync()
        return .result(value: result.message + " 训练数据将在 10 分钟后再复查一次。")
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
        AppShortcut(
            intent: WorkoutEndedHealthSyncIntent(),
            phrases: [
                "用\(.applicationName)同步刚结束的训练",
                "让\(.applicationName)复查训练数据",
            ],
            shortTitle: "训练结束后同步",
            systemImageName: "figure.run.circle"
        )
    }
}
