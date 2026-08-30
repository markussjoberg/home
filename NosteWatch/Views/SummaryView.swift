import SwiftUI
import NosteCore

struct SummaryView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @State private var rating: WindRating?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = workout.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let summary = workout.summary {
                    Label { Text(summary.sport.displayName) } icon: {
                        SportIcon(sport: summary.sport, size: 20).foregroundStyle(.tint)
                    }
                        .font(.headline)

                    row("Kesto", Format.duration(summary.duration))
                    row("Matka", Format.distance(summary.distance))
                    row("Maksimi", Format.speedKmh(summary.maxSpeed))
                    if let heart = summary.heartRate {
                        row("Syke", "\(Int(heart.average.rounded())) / \(Int(heart.max.rounded()))")
                    }

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
                        if let attempts = summary.rides.attemptCount, let rate = summary.rides.successRate {
                            row("Startit", "\(summary.rides.count)/\(attempts) (\(Format.percent(rate)))")
                        }
                        row("Pumput", "\(pumps.strokeCount)")
                        row("Kadenssi", String(format: "%.0f/min", pumps.averageCadence))
                        row("Pumppausaika", Format.duration(pumps.totalBoutTime))
                        if let swimTime = pumps.swimTime {
                            row("Uinnissa", Format.duration(swimTime))
                        }
                    }
                    if summary.sport == .surf || summary.sport == .sup {
                        Divider()
                        row(summary.sport == .surf ? "Aaltoja" : "Vetoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                    }

                    Divider()
                    ratingSection(summary: summary)

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

    /// Tuuliarvosana: tähdet tai "ei riittänyt". Lähetetään puhelimeen, joka
    /// hakee session ajalta toteutuneen tuulen ja opettaa spotin tuuliprofiilia.
    private func ratingSection(summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Millainen tuuli?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        select(WindRating(rawValue: star)!, summary: summary)
                    } label: {
                        Image(systemName: star <= (rating?.rawValue ?? 0) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                select(.insufficient, summary: summary)
            } label: {
                Text("Ei riittänyt")
                    .font(.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(rating == .insufficient ? Color.orange : Color(white: 0.15),
                                in: Capsule())
                    .foregroundStyle(rating == .insufficient ? .black : .primary)
            }
            .buttonStyle(.plain)
            if rating != nil {
                Text("Kiitos — spotti oppii tästä.")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private func select(_ value: WindRating, summary: SessionSummary) {
        rating = value
        WatchConnectivityManager.shared.send(rating: value, for: summary.startDate)
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
