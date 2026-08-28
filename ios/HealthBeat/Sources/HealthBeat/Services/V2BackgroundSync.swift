import BackgroundTasks
import Foundation

@MainActor
final class V2BackgroundSyncCoordinator {
    static let shared = V2BackgroundSyncCoordinator()
    static var refreshIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "org.healthtracker.collector").refresh"
    }

    private var registered = false
    private var runningTask: Task<Void, Never>?
    private var completionSent = false

    private init() {}

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handle(refreshTask)
            }
        }
    }

    func scheduleNext(earliest: TimeInterval = 60 * 60) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[V2BackgroundSync] schedule failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        completionSent = false
        let work = Task { @MainActor in
            let success = await PersonalHealthSyncService.shared.performBackgroundRefresh()
            finish(task, success: success && !Task.isCancelled)
        }
        runningTask = work
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.runningTask?.cancel()
                self?.finish(task, success: false)
            }
        }
    }

    private func finish(_ task: BGAppRefreshTask, success: Bool) {
        guard !completionSent else { return }
        completionSent = true
        task.setTaskCompleted(success: success)
        runningTask = nil
    }
}
