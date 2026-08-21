import SwiftUI

@main
struct NosteWatchApp: App {
    @StateObject private var workout = WorkoutManager()
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(workout)
                .environmentObject(connectivity)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        NavigationStack {
            switch workout.phase {
            case .idle:
                StartView()
            case .running:
                SessionPagingView()
            case .ended:
                SummaryView()
            }
        }
        .onAppear {
            workout.requestAuthorization()
        }
    }
}
