import Foundation
import SwiftData
import NosteCore

/// Spotin tallennus ja poisto yhdestä paikasta: kartta ja Spotit-välilehti
/// tekevät saman (SwiftData, julkaisu yhteispooliin, ennuste, varmuuskopio,
/// maastoanalyysi). Ennen logiikka asui kartassa eikä Spotit-välilehdeltä
/// päässyt muokkaamaan.
@MainActor
enum SpotEditing {
    struct Effects {
        /// Julkisten spottien lista päivittyi (kartta näyttää ne).
        var publicSpotsChanged: ([ServerClient.PublicSpot]) -> Void = { _ in }
        /// Julkaisun poisto eteni ehdotuksena tai epäonnistui — kerrottava käyttäjälle.
        var unpublished: (ServerClient.UnpublishResult) -> Void = { _ in }
    }

    static func apply(_ action: SpotEditorView.Action, original: SpotData, spots: [SpotRecord],
                      context: ModelContext, forecastStore: ForecastStore, effects: Effects = Effects()) {
        switch action {
        case .save(let data):
            let record: SpotRecord
            if let existing = spots.first(where: { $0.id == data.id }) {
                existing.update(from: data)
                record = existing
            } else {
                record = SpotRecord(from: data)
                context.insert(record)
            }
            try? context.save()
            // @Query päivittyy asynkronisesti — rakenna ajantasainen lista itse.
            var updated = spots.map(\.data).filter { $0.id != data.id }
            updated.append(data)
            Task {
                // Julkinen spotti näkyy kaikille — julkaisu/poisto yhteispoolista.
                if data.isPublic == true {
                    await ServerClient.shared.publishSpot(data)
                } else if original.isPublic == true {
                    effects.unpublished(await ServerClient.shared.unpublishSpot(id: data.id))
                }
                if let shared = await ServerClient.shared.publicSpots() {
                    effects.publicSpotsChanged(shared)
                }
                await forecastStore.refresh(spot: data, force: true, allSpots: updated)
                await ServerClient.shared.backupSpots(updated)
                // Uusi suosikki saa offline-kartan ja vesimaskin kelloon heti, ei vasta seuraavassa käynnistyksessä.
                await MapSnapshotService.shared.syncFavorites(spots: updated)
                // Maastoanalyysi kerran per spotti: fetch + avoimuus ilmansuunnittain.
                if record.fetchKmByOctant == nil,
                   let meta = await ServerClient.shared.spotMeta(latitude: data.latitude, longitude: data.longitude) {
                    let sorted = meta.octants.sorted { $0.octant < $1.octant }
                    record.fetchKmByOctant = sorted.map(\.fetchKm)
                    record.exposureByOctant = sorted.map(\.exposure)
                    try? context.save()
                }
            }
        case .delete:
            if let existing = spots.first(where: { $0.id == original.id }) {
                context.delete(existing)
                try? context.save()
                let remaining = spots.map(\.data).filter { $0.id != original.id }
                Task {
                    // Poistopyyntö palvelimelle vain jos spotti oli julkaistu.
                    if original.isPublic == true {
                        effects.unpublished(await ServerClient.shared.unpublishSpot(id: original.id))
                        if let shared = await ServerClient.shared.publicSpots() { effects.publicSpotsChanged(shared) }
                    }
                    await ServerClient.shared.backupSpots(remaining)
                }
            }
        case .cancel:
            break
        }
    }
}
