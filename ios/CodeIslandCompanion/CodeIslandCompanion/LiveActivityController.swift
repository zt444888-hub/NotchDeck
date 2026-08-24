import ActivityKit
import Foundation

@MainActor
final class LiveActivityController: ObservableObject {
    private static let layoutVersionKey = "CodeIslandLiveActivityLayoutVersion"
    private static let currentLayoutVersion = "2026-05-29-compact-multi-session-v3"

    @Published private(set) var activityID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var existingActivityCount = 0

    /// Set once the user explicitly stops the Live Activity. Persisted to
    /// UserDefaults (see `userStoppedKey`) so the intent survives app
    /// termination — without this, a killed/relaunched app would forget the
    /// stop and the next Mac heartbeat would resurrect the Dynamic Island.
    /// While set, automatic drivers (Mac state push, scene-phase resume)
    /// must NOT recreate it.
    private static let userStoppedKey = "CodeIslandLiveActivityUserStopped"
    private var userStopped: Bool {
        didSet { UserDefaults.standard.set(userStopped, forKey: Self.userStoppedKey) }
    }

    private var activity: Activity<CodeIslandActivityAttributes>?
    private var lastContentState: CodeIslandActivityAttributes.ContentState?
    private var activityStateTask: Task<Void, Never>?
    /// Tracks whether the app is in the foreground. Gates CREATION of new
    /// activities (startOrUpdate only creates when foregrounded), so a
    /// background state push can't rebuild an island the user stopped — but
    /// it does NOT gate updates: an existing activity keeps refreshing in the
    /// background, which is the whole point of a Live Activity. Unlike
    /// `userStopped`, this is NOT persisted: returning to the foreground
    /// resumes the activity from `latestState`.
    private var isAppActive = true

    var isRunning: Bool {
        activity != nil
    }

    deinit {
        activityStateTask?.cancel()
    }

    init() {
        // Restore the persisted stop intent so a relaunch can't resurrect an
        // island the user already dismissed in a previous session.
        userStopped = UserDefaults.standard.bool(forKey: Self.userStoppedKey)
        Task {
            await migrateLiveActivityLayoutIfNeeded()
            if userStopped {
                // Belt-and-suspenders: end any activity that survived the
                // previous session so the island can't reappear on launch.
                for activity in Activity<CodeIslandActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                clearActivity(id: activityID)
            } else {
                recoverExistingActivity()
            }
        }
    }

    func updateIfRunning(with payload: CompanionStatePayload) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !userStopped else { return }

        Task {
            let shouldRecreate = await migrateLiveActivityLayoutIfNeeded()
            await recoverExistingActivity(endingDuplicates: true)
            guard activity != nil || shouldRecreate else { return }
            await apply(payload, createIfNeeded: shouldRecreate)
        }
    }

    /// User-initiated start (the "Start" / "Sync" buttons). Clears any prior
    /// explicit stop so the activity is allowed to appear again.
    func userStart(with payload: CompanionStatePayload) {
        userStopped = false
        startOrUpdate(with: payload)
    }

    func startOrUpdate(with payload: CompanionStatePayload) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = L10n.t(zh: "这台 iPhone 没有开启实时活动。", en: "Live Activities are turned off on this iPhone.")
            return
        }
        guard !userStopped else { return }

        Task {
            await migrateLiveActivityLayoutIfNeeded()
            await recoverExistingActivity(endingDuplicates: true)
            // Foreground: create if none exists. Background: update an
            // existing activity only — never create one, so the island can't
            // be resurrected by a background state push after a stop.
            guard activity != nil || isAppActive else { return }
            await apply(payload, createIfNeeded: isAppActive)
        }
    }

    func stop() {
        stopAll()
    }

    func stopAll() {
        userStopped = true
        Task {
            for activity in Activity<CodeIslandActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            clearActivity(id: activityID)
            existingActivityCount = 0
            lastError = nil
        }
    }

    /// Driven by the app scene when it enters/leaves the foreground.
    ///
    /// Merely tracks foreground state — it does NOT dismiss the activity.
    /// A Live Activity is meant to persist after the app leaves the
    /// foreground (that's its entire purpose: keep showing the Mac's status
    /// on the Lock Screen / Dynamic Island while you do other things). The
    /// island is dismissed only by an explicit Stop (`stopAll`, persisted
    /// `userStopped`) — and `startOrUpdate` gates creation on `isAppActive`
    /// so a background push can never resurrect a stopped island.
    func setAppActive(_ active: Bool) {
        isAppActive = active
    }

    private func recoverExistingActivity() {
        existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
        guard activity == nil, let existing = newestExistingActivity() else { return }
        activity = existing
        activityID = existing.id
        lastContentState = existing.content.state
        observeState(of: existing)
    }

    private func recoverExistingActivity(endingDuplicates: Bool) async {
        existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
        guard let existing = newestExistingActivity() else {
            if activity != nil {
                clearActivity(id: activityID)
            }
            return
        }

        if activityID != existing.id {
            activity = existing
            activityID = existing.id
            lastContentState = existing.content.state
            observeState(of: existing)
        }

        guard endingDuplicates else { return }
        for duplicate in Activity<CodeIslandActivityAttributes>.activities where duplicate.id != existing.id {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
        existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
    }

    private func newestExistingActivity() -> Activity<CodeIslandActivityAttributes>? {
        Activity<CodeIslandActivityAttributes>.activities.max {
            $0.content.state.updatedAt < $1.content.state.updatedAt
        }
    }

    @discardableResult
    private func migrateLiveActivityLayoutIfNeeded() async -> Bool {
        let storedVersion = UserDefaults.standard.string(forKey: Self.layoutVersionKey)
        guard storedVersion != Self.currentLayoutVersion else { return false }

        let existingActivities = Activity<CodeIslandActivityAttributes>.activities
        for activity in existingActivities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if !existingActivities.isEmpty {
            clearActivity(id: activityID)
        }
        existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
        UserDefaults.standard.set(Self.currentLayoutVersion, forKey: Self.layoutVersionKey)
        return !existingActivities.isEmpty
    }

    private func apply(_ payload: CompanionStatePayload, createIfNeeded: Bool) async {
        do {
            let contentState = CodeIslandActivityAttributes.ContentState(payload: payload)
            lastContentState = contentState

            if let activity {
                await update(activity, with: contentState, status: payload.status)
                lastError = nil
                return
            }

            guard createIfNeeded else { return }
            let attributes = CodeIslandActivityAttributes(sessionId: payload.sessionId)
            let content = ActivityContent(
                state: contentState,
                staleDate: Date().addingTimeInterval(300),
                relevanceScore: relevanceScore(for: payload.status)
            )
            let existing = try Activity.request(attributes: attributes, content: content)
            activity = existing
            activityID = existing.id
            observeState(of: existing)
            lastError = nil
            existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
        } catch {
            lastError = error.localizedDescription
            recoverExistingActivity()
        }
    }

    private func update(
        _ activity: Activity<CodeIslandActivityAttributes>,
        with contentState: CodeIslandActivityAttributes.ContentState,
        status: CompanionStatus
    ) async {
        await activity.update(ActivityContent(
            state: contentState,
            staleDate: Date().addingTimeInterval(300),
            relevanceScore: relevanceScore(for: status)
        ))
    }

    private func observeState(of activity: Activity<CodeIslandActivityAttributes>) {
        activityStateTask?.cancel()
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self?.clearActivity(id: activity.id)
                break
            }
        }
    }

    private func clearActivity(id: String?) {
        guard activityID == nil || activityID == id else { return }
        activity = nil
        activityID = nil
        lastContentState = nil
        existingActivityCount = Activity<CodeIslandActivityAttributes>.activities.count
        activityStateTask?.cancel()
        activityStateTask = nil
    }

    private func relevanceScore(for status: CompanionStatus) -> Double {
        switch status {
        case .waitingApproval, .waitingQuestion:
            return 1
        case .processing, .running:
            return 0.7
        case .idle:
            // Kept above the "background noise" threshold so the Dynamic
            // Island doesn't get collapsed/aged out by the system between
            // agent activities (was 0.25 → island blinked away quickly).
            return 0.5
        }
    }
}
