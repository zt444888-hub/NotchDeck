import SwiftUI

@main
struct CodeIslandCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var connection: CompanionConnection
    @StateObject private var liveActivity: LiveActivityController
    @StateObject private var remoteAI: RemoteConversationViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let connection = CompanionConnection()
        let liveActivity = LiveActivityController()
        let remoteAI = RemoteConversationViewModel()
        connection.onStateReceived = { [weak liveActivity] state in
            Task { @MainActor in
                // startOrUpdate (not updateIfRunning): the very first state
                // must CREATE the activity — updateIfRunning only refreshes
                // an existing one, so the Dynamic Island never appeared for
                // a fresh connection.
                liveActivity?.startOrUpdate(with: state)
            }
        }
#if DEBUG
        Self.configureSmokeTestHooks(connection: connection, liveActivity: liveActivity)
#endif
        _connection = StateObject(wrappedValue: connection)
        _liveActivity = StateObject(wrappedValue: liveActivity)
        _remoteAI = StateObject(wrappedValue: remoteAI)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connection)
                .environmentObject(liveActivity)
                // Shared Remote AI view model: ONE poll timer + ONE zone
                // token, so the main screen and the Mac-session sheet see the
                // same conversations/status without competing over the
                // CloudKit change token.
                .environmentObject(remoteAI)
        }
        // MultipeerConnectivity sessions don't survive backgrounding; without
        // this, returning to the foreground after minimizing the app or
        // locking the phone left it stuck showing "disconnected" (#261).
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .background, newPhase == .active else { return }
            connection.reconnectIfNeeded()
            // App updates / long background periods can leave the Dynamic
            // Island with no live activity (the system ends activities on
            // app update, and nothing recreates them until the NEXT state
            // arrives). Rebuilding from the last cached state brings the
            // island back immediately instead of waiting for the next MPC
            // heartbeat.
            if let state = connection.latestState {
                liveActivity.startOrUpdate(with: state)
            }
        }
    }

#if DEBUG
    private static func configureSmokeTestHooks(
        connection: CompanionConnection,
        liveActivity: LiveActivityController
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-CodeIslandCompanionSmokeLiveActivity") else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let state = connection.latestState {
                liveActivity.startOrUpdate(with: state)
            }

            guard let flagIndex = arguments.firstIndex(of: "-CodeIslandCompanionSmokeDelayedState"),
                  arguments.indices.contains(flagIndex + 1)
            else { return }

            try? await Task.sleep(nanoseconds: 4_000_000_000)
            connection.injectMockState(named: arguments[flagIndex + 1])
        }
    }
#endif
}
