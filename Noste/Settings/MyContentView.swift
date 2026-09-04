import SwiftUI
import NosteCore

/// Omat julkaisut: tilin (ja siihen sidottujen laitteiden) julkiset spotit ja
/// kommentit yhdessä paikassa — poisto onnistuu ilman että kohdetta pitää etsiä.
struct MyContentView: View {
    @State private var content: ServerClient.MyContent?
    @State private var notice: String?

    var body: some View {
        List {
            if let content {
                Section("Julkaistut spotit") {
                    if content.spots.isEmpty {
                        Text("Et ole julkaissut spotteja.").foregroundStyle(.secondary)
                    }
                    ForEach(content.spots) { spot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name).font(.subheadline.weight(.semibold))
                            Text(spot.deletionProposed != nil
                                 ? "Poistoehdotus vireillä"
                                 : "\(spot.commentCount) kommenttia")
                                .font(.caption).foregroundStyle(spot.deletionProposed != nil ? .orange : .secondary)
                        }
                        .swipeActions {
                            Button("Poista julkaisu", role: .destructive) {
                                Task { await unpublish(spot) }
                            }
                        }
                    }
                }
                Section("Kommentit") {
                    if content.comments.isEmpty {
                        Text("Et ole kommentoinut.").foregroundStyle(.secondary)
                    }
                    ForEach(content.comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.text).font(.subheadline)
                            Text(ISO8601.parse(comment.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Poista", role: .destructive) {
                                Task {
                                    if await ServerClient.shared.deleteComment(spotID: comment.spotId, commentID: comment.id) {
                                        await reload()
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Omat julkaisut")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowBackground(Theme.surface)
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Julkinen spotti on yhteinen", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func reload() async {
        content = await ServerClient.shared.myContent()
    }

    private func unpublish(_ spot: ServerClient.PublicSpot) async {
        guard let id = UUID(uuidString: spot.id) else { return }
        switch await ServerClient.shared.unpublishSpot(id: id) {
        case .deleted:
            await reload()
        case .proposed:
            notice = "Muut ovat lisänneet spottiin sisältöä, joten poisto toteutuu 7 päivän kuluttua, ellei kukaan osallistunut vastusta."
            await reload()
        case .failed:
            notice = "Poisto ei onnistunut. Yritä myöhemmin."
        }
    }
}
