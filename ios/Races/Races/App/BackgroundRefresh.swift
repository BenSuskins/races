import Foundation
import BackgroundTasks
import RacesKit

/// Fetches results while the app isn't open.
///
/// This exists because of one property of the free tier: `/results/today/free`
/// covers **today only**. A race day the app never runs on is a day of results
/// gone for good — and with them the jockey and trainer records that only ever
/// accumulate from what we saw. A background task is the difference between a
/// history that fills in by itself and one that depends on remembering to open an
/// app in the evening.
///
/// It reuses `AppEnvironment.refreshResults()` rather than reimplementing the
/// fetch. A second copy of that logic would be a second thing that can quietly
/// stop working, and this one runs where nobody is watching.
nonisolated enum BackgroundRefresh {

    /// Must also appear in `BGTaskSchedulerPermittedIdentifiers` in Info.plist,
    /// or registration traps at launch.
    static let taskIdentifier = "uk.co.suskins.Races.refresh"

    /// Evening, when the day's results exist and are about to stop existing.
    /// The system decides when to actually run it; this is the earliest we would
    /// find anything worth having.
    static let earliestDelay: TimeInterval = 2 * 60 * 60

    @MainActor
    static func register(environment: AppEnvironment) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, environment: environment)
        }
    }

    @MainActor
    static func schedule(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(earliestDelay)
        // Throws in the simulator and whenever background refresh is switched
        // off. Neither is a fault worth surfacing: the foreground path still
        // collects results whenever the app is opened.
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask, environment: AppEnvironment) {
        // Always ask for the next one first. If this run is killed, an
        // un-rescheduled task never comes back, and the failure is silent.
        schedule()

        let work = Task {
            let ingestion = await environment.refreshResults()
            task.setTaskCompleted(success: ingestion != nil)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
