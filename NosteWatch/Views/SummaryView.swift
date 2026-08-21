import SwiftUI
import NosteCore

struct SummaryView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = workout.summary {
                    Text(summary.sport.displayName)
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
                    }
                    if let pumps = summary.pumps {
                        Divider()
                        row("Pumput", "\(pumps.strokeCount)")
                        row("Kadenssi", String(format: "%.0f/min", pumps.averageCadence))
                    }
                    if summary.sport == .surf {
                        Divider()
                        row("Aaltoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin aalto", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                    }
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
