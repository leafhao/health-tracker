import SwiftUI
import UIKit

@MainActor
final class HealthBeatAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // HealthKit can cold-launch the process before SwiftUI creates a scene.
        // Observer queries must exist now, not after ContentView.task/prepare().
        V2BackgroundSyncCoordinator.shared.register()
        PersonalHealthSyncService.shared.registerBackgroundObserversAtLaunch()
        V2BackgroundSyncCoordinator.shared.scheduleNext(earliest: 15 * 60)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundHTTPTransferCenter.shared.handleEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct HealthBeatApp: App {

    @UIApplicationDelegateAdaptor(HealthBeatAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    init() {
        V2BackgroundSyncCoordinator.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await PersonalHealthSyncService.shared.prepare()
                    // scenePhase may already be active before this view is created, so
                    // onChange is not guaranteed to fire on a cold launch. Explicitly
                    // perform the throttled foreground catch-up after preparation.
                    await PersonalHealthSyncService.shared.syncOnForegroundIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await PersonalHealthSyncService.shared.syncOnForegroundIfNeeded()
                }
            } else if phase == .background {
                V2BackgroundSyncCoordinator.shared.scheduleNext()
            }
        }
    }
}
