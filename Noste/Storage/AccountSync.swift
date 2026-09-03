import Foundation
import SwiftData
import NosteCore

/// Tilin synkka kirjautumisen yhteydessä: puhelimen spotit ja hälytykset
/// palvelimelle tilin alle, ja tyhjään puhelimeen palautus palvelimelta.
/// Sessioita ei synkata — ne pysyvät puhelimessa.
@MainActor
enum AccountSync {
    static func afterSignIn(context: ModelContext) async {
        let spots = (try? context.fetch(FetchDescriptor<SpotRecord>())) ?? []
        if spots.isEmpty, let remote = await ServerClient.shared.fetchMySpots(), !remote.isEmpty {
            // Uusi puhelin tai uudelleenasennus: palauta tilin spotit.
            for spot in remote { context.insert(SpotRecord(from: spot)) }
            try? context.save()
        } else {
            await ServerClient.shared.backupSpots(spots.map(\.data))
        }
        let alerts = (try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []
        if alerts.isEmpty, let remote = await ServerClient.shared.fetchMyAlerts(), !remote.isEmpty {
            for alert in remote { context.insert(AlertRecord(from: alert)) }
            try? context.save()
        } else {
            await ServerClient.shared.backupAlerts(alerts.map(\.data))
        }
    }
}
