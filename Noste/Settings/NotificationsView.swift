import SwiftUI
import SwiftData
import NosteCore

/// Tilin ilmoitukset: poistoehdotukset osallistuttuihin spotteihin ja uudet
/// kommentit omiin. Haetaan palvelimelta — push-kanavaa ei ole.
struct NotificationsView: View {
    @State private var items: [ServerClient.Notification]?
    @Query private var spots: [SpotRecord]
    @EnvironmentObject private var forecastStore: ForecastStore
    @State private var publicTarget: ServerClient.PublicSpot?
    @State private var publicSpots: [ServerClient.PublicSpot] = []

    var body: some View {
        List {
            if let items {
                if items.isEmpty { Text("Ei ilmoituksia.").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    // Napautus vie spotin sivulle: oma spotti suoraan, julkinen sheetinä.
                    if let own = spots.first(where: { $0.id.uuidString.lowercased() == item.spotId.lowercased() }) {
                        NavigationLink {
                            SpotForecastView(spot: own.data, allSpots: spots.map(\.data))
                        } label: {
                            NotificationRow(item: item)
                        }
                    } else {
                        Button {
                            publicTarget = publicSpots.first { $0.id.lowercased() == item.spotId.lowercased() }
                        } label: {
                            NotificationRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Ilmoitukset")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowBackground(Theme.surface)
        .sheet(item: $publicTarget) { spot in PublicSpotView(spot: spot) }
        .task {
            items = await ServerClient.shared.notifications()
            publicSpots = await ServerClient.shared.publicSpots() ?? []
            // Näytetty = luettu; laskuri nollautuu.
            await ServerClient.shared.markNotificationsRead()
            await UserAccount.shared.refresh()
        }
        .refreshable { items = await ServerClient.shared.notifications() }
    }
}

private struct NotificationRow: View {
    let item: ServerClient.Notification

    var body: some View {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.kind == "comment" ? "bubble.left.fill" : item.kind == "kelivahti" ? "wind" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.kind == "comment" ? .cyan : item.kind == "kelivahti" ? Theme.wind : .orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.spotName).font(.subheadline.weight(item.read ? .regular : .semibold))
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                            Text(ISO8601.parse(item.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
    }
}
