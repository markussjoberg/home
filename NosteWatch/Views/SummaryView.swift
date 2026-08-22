import SwiftUI
import NosteCore

struct SummaryView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = workout.summary {
                    Label(summary.sport.displayName, systemImage: summary.sport.symbolName)
                        .font(.headline)

                    row("Kesto", Format.duration(summary.duration))
                    row("Matka", Format.distance(summary.distance))
                    row("Maksimi", Format.speedKmh(summary.maxSpeed))

                    if summary.sport.usesFoil {
                        Divider()
                        row("Foiliaika", "\(Format.duration(summary.rides.totalDuration)) (\(Format.percent(summary.rideFraction)))")
                        row("Lentoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin lento", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                        if summary.rides.count > 1 {
                            row("Keskilento", Format.duration(summary.rides.averageDuration))
                        }
                    }
                    if let pumps = summary.pumps {
                        Divider()
                        row("Pumput", "\(pumps.strokeCount)")
                        row("Kadenssi", String(format: "%.0f/min", pumps.averageCadence))
                        row("Pumppausjaksoja", "\(pumps.bouts.count)")
                    }
                    if summary.sport == .surf || summary.sport == .sup {
                        Divider()
                        row(summary.sport == .surf ? "Aaltoja" : "Vetoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                    }

                    Text("Sessio siirtyy puhelimeen automaattisesti.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    Text("Ei dataa")
                }

                Button("Valmis") {
                    workout.reset()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Yhteenveto")
        .navigationBarBackButtonHidden(true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.footnote)
    }
}
