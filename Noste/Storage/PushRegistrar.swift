import UIKit
import UserNotifications

/// Push-ilmoitukset: pyydetään lupa kirjautumisen jälkeen ja lähetetään
/// laitetunniste palvelimelle tilin alle. Ilman Applen APNs-avainta palvelin
/// ei lähetä mitään — silloin ilmoitukset näkyvät vain appin Ilmoituksissa.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        Task { await ServerClient.shared.registerPushToken(token, sandbox: sandbox) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulaattori tai ei verkkoa: ilmoitukset jäävät appin sisäisiksi.
    }

    /// Näytetään myös appin ollessa auki — kelin osuma on aina kiinnostava.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

enum PushRegistrar {
    /// Kysyy luvan (kerran) ja rekisteröi laitteen. Kutsutaan kirjautumisen jälkeen
    /// ja käynnistyksessä kirjautuneena — tunniste voi vaihtua.
    @MainActor
    static func registerIfAllowed() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }
}
