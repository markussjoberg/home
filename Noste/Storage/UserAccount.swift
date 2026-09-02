import Foundation
import Security
import AuthenticationServices
import NosteCore

/// Käyttäjätili: Sign in with Apple + nimimerkki. Istuntotunniste on
/// Keychainissa, käyttäjätiedot UserDefaultsissa (näytettäviä, ei salaisia).
/// Ilman tiliä appi toimii kuten ennen: laiteavain omistaa spotit ja kommentit
/// kulkevat vapaalla nimimerkillä. Kirjautuminen sitoo laiteavaimen tiliin.
@MainActor
final class UserAccount: ObservableObject {
    struct User: Codable, Equatable {
        var id: String
        var nickname: String?
        var email: String?
        var role: String
    }

    static let shared = UserAccount()

    @Published private(set) var user: User?
    @Published var lastError: String?
    /// Lukemattomat ilmoitukset (päivittyy refreshissä).
    @Published private(set) var unreadNotifications = 0

    private static let tokenKey = "userToken"
    private static let userKey = "userAccount"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userKey) {
            user = try? JSONDecoder().decode(User.self, from: data)
        }
        if token == nil { user = nil }
    }

    var isSignedIn: Bool { user != nil && token != nil }

    /// Istuntotunniste palvelimelle (X-User-Token). Luetaan Keychainista pyyntöä varten.
    nonisolated var token: String? { KeychainStore.read(Self.tokenKey) }

    /// Applen kirjautumisen tulos → palvelimen istunto.
    func signIn(with authorization: ASAuthorization) async {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            lastError = "Applen tunnistus ei antanut tunnistetta."
            return
        }
        guard let result = await ServerClient.shared.signInWithApple(identityToken: identityToken, ownerKey: ServerSettings.deviceKey) else {
            lastError = "Kirjautuminen palvelimelle epäonnistui."
            return
        }
        KeychainStore.write(Self.tokenKey, result.token)
        store(user: result.user)
        lastError = nil
    }

    func setNickname(_ nickname: String) async -> Bool {
        guard token != nil else { return false }
        switch await ServerClient.shared.setNickname(nickname, ownerKey: ServerSettings.deviceKey) {
        case .success(let updated):
            store(user: updated)
            lastError = nil
            return true
        case .failure(let message):
            lastError = message
            return false
        }
    }

    /// Päivittää tilin tiedot palvelimelta; vanhentunut tunniste kirjaa ulos.
    func refresh() async {
        guard token != nil else { return }
        switch await ServerClient.shared.me() {
        case .success(let fresh):
            store(user: fresh)
            unreadNotifications = await ServerClient.shared.unreadNotifications() ?? unreadNotifications
        case .unauthorized: signOutLocally()
        case .unavailable: break
        }
    }

    func signOut() async {
        await ServerClient.shared.logout()
        signOutLocally()
    }

    private func signOutLocally() {
        KeychainStore.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        user = nil
        unreadNotifications = 0
    }

    private func store(user: User) {
        self.user = user
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
    }
}

/// Pieni Keychain-kuori yhdelle palvelulle: istuntotunniste ei kuulu UserDefaultsiin.
enum KeychainStore {
    private static let service = "fi.markussjoberg.noste"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
