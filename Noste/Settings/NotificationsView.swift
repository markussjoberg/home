import SwiftUI
import NosteCore

/// Tilin ilmoitukset: poistoehdotukset osallistuttuihin spotteihin ja uudet
/// kommentit omiin. Haetaan palvelimelta — push-kanavaa ei ole.
struct NotificationsView: View {
    @State private var items: [ServerClient.Notification]?

    var body: some View {
        List {
            if let items {
                if items.isEmpty { Text("Ei ilmoituksia.").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.kind == "comment" ? "bubble.left.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.kind == "comment" ? .cyan : .orange)
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
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Ilmoitukset")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowBackground(Theme.surface)
        .task {
            items = await ServerClient.shared.notifications()
            // Näytetty = luettu; laskuri nollautuu.
            await ServerClient.shared.markNotificationsRead()
            await UserAccount.shared.refresh()
        }
        .refreshable { items = await ServerClient.shared.notifications() }
    }
}
