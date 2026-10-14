@preconcurrency import BackgroundTasks
import SugarbarCore
import UIKit

let backgroundRefreshTaskIdentifier = "com.sugarbar.Sugarbar.refresh"

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshTaskIdentifier, using: nil) { task in
            handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
        scheduleBackgroundRefresh()
        return true
    }
}

// Best-effort only — iOS may defer, coalesce, or skip BGAppRefreshTask entirely, especially overnight.
func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
        try BGTaskScheduler.shared.submit(request)
    } catch {
        logDiagnostic("scheduleBackgroundRefresh", error)
    }
}

private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
    scheduleBackgroundRefresh()
    let poll = Task {
        let outcome = await GlucoseViewModel().pollOnce(includingInsulin: false)
        switch outcome {
        case .success:
            task.setTaskCompleted(success: true)
        case .rateLimited, .transientFailure:
            task.setTaskCompleted(success: false)
        }
    }
    task.expirationHandler = {
        poll.cancel()
    }
}
