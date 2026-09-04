import SwiftUI
import SwiftData

@main
struct NosteApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: SpotRecord.self, SessionRecord.self, GearRecord.self, AlertRecord.self)
        } catch {
            fatalError("SwiftData-säiliö ei auennut: \(error)")
        }
        PhoneConnectivity.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
