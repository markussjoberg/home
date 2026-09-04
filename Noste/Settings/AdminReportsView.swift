import SwiftUI
import NosteCore

/// Moderointi admin-tokenilla (kehittäjäasetukset): avoimet ilmoitukset kohteen
/// tiedoilla, kohteen poisto ja ilmoituksen merkintä käsitellyksi.
struct AdminReportsView: View {
    @State private var reports: [ServerClient.AdminReport]?
    @State private var busy = false

    var body: some View {
        List {
            if let reports {
                if reports.isEmpty { Text("Ei avoimia ilmoituksia.").foregroundStyle(.secondary) }
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(report.targetType == "spot" ? "Spotti" : "Kommentti",
                                  systemImage: report.targetType == "spot" ? "mappin" : "bubble.left")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(ISO8601.parse(report.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let name = report.target.spotName { Text(name).font(.subheadline) }
                        if let text = report.target.text {
                            Text("\(report.target.author ?? "?"): \(text)").font(.subheadline)
                        }
                        Text("Syy: \(report.reason)").font(.caption).foregroundStyle(Theme.ride)
                        if report.target.deleted == true {
                            Text("Kohde on jo poistettu").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if report.target.deleted != true {
                                Button(report.targetType == "spot" ? "Poista spotti" : "Poista kommentti", role: .destructive) {
                                    Task { await remove(report) }
                                }
                                .buttonStyle(.bordered)
                            }
                            Button("Käsitelty, ei toimia") {
                                Task { await resolve(report, resolution: "ei toimia") }
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption)
                        .disabled(busy)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Ilmoitukset (admin)")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .task { reports = await ServerClient.shared.adminReports() }
        .refreshable { reports = await ServerClient.shared.adminReports() }
    }

    private func remove(_ report: ServerClient.AdminReport) async {
        busy = true
        let ok: Bool
        if report.targetType == "spot" {
            ok = await ServerClient.shared.adminDeleteSpot(id: report.targetId)
        } else if let spotID = report.target.spotId {
            ok = await ServerClient.shared.adminDeleteComment(spotID: spotID, commentID: report.targetId)
        } else {
            ok = false
        }
        if ok { await resolve(report, resolution: "kohde poistettu") }
        busy = false
    }

    private func resolve(_ report: ServerClient.AdminReport, resolution: String) async {
        busy = true
        if await ServerClient.shared.resolveReport(id: report.id, resolution: resolution) {
            reports = await ServerClient.shared.adminReports()
        }
        busy = false
    }
}
