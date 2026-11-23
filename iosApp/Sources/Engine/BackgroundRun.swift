import BackgroundTasks
import UIKit

/// Keeps a user-started job alive after the app leaves the screen.
///
/// - iOS 26+: a continued-processing task. iOS shows its progress in the system UI and lets it
///   run to the end while the work keeps reporting progress.
/// - Earlier iOS, or when the system turns that down: the classic background window, roughly
///   30 seconds. When it runs out, `onExpire` stops the job so it can resume on return.
@MainActor
final class BackgroundRun {
    private let title: String
    private let kind: String
    private let onExpire: () -> Void
    private var total: Int64
    private var completed: Int64 = 0
    private var subtitle: String
    private var finished = false
    private var legacyID: UIBackgroundTaskIdentifier = .invalid
    /// The BGContinuedProcessingTask, kept untyped so the class builds for iOS 16.
    private var continued: AnyObject?

    /// `kind` names the job in the task identifier ("<bundle id>.<kind>.<uuid>"); it must have a
    /// matching entry in BGTaskSchedulerPermittedIdentifiers.
    init(
        kind: String = "libraryupdate",
        title: String, subtitle: String, total: Int, onExpire: @escaping () -> Void
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.total = Int64(max(total, 1))
        self.onExpire = onExpire

        legacyID = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            Task { @MainActor in self?.legacyExpired() }
        }
        if #available(iOS 26.0, *) {
            submitContinued()
        }
    }

    func update(completed: Int, subtitle: String) {
        self.completed = Int64(completed)
        self.subtitle = subtitle
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = self.completed
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    /// For jobs whose size changes while they run (a download queue that keeps growing).
    func update(completed: Int, total: Int, subtitle: String) {
        self.total = Int64(max(total, 1))
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = self.total
        }
        update(completed: completed, subtitle: subtitle)
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = total
            task.setTaskCompleted(success: success)
        }
        continued = nil
        endLegacy()
    }

    // MARK: - iOS 26

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // Must match BGTaskSchedulerPermittedIdentifiers ("<bundle id>.<kind>.*").
        // Each run gets its own identifier, registered right before it is submitted.
        let identifier = "\(bundleID).\(kind).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let self, !self.finished else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: subtitle
        )
        // Start now or not at all: a run that waits in a queue is no use to someone reading.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Turned down (too many running, low power…): the classic window still applies.
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        continued = task
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
        task.updateTitle(title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedExpired() }
        }
    }

    private func continuedExpired() {
        guard !finished else { return }
        onExpire()
        finish(success: false)
    }

    // MARK: - Classic window

    private func legacyExpired() {
        // With a continued task running, the short window ending changes nothing.
        if continued == nil && !finished {
            onExpire()
            finished = true
        }
        endLegacy()
    }

    private func endLegacy() {
        guard legacyID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyID)
        legacyID = .invalid
    }
}
