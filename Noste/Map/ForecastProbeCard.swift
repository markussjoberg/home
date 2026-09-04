import SwiftUI
import MapKit
import NosteCore

/// Windy-tyylinen ennustepiste: napautus kartalle näyttää kohdan tuulen ja
/// aallokon valitulle aikajanan tunnille suoraan ladatuista kentistä — ei
/// uutta hakua. Täysi ennuste ja spotin lisäys yhdellä napilla.
struct ForecastProbeCard: View {
    struct Wind {
        var speed: Double
        /// Suunta josta tuulee (°).
        var direction: Double
    }
    struct Wave {
        var height: Double
        /// Suunta josta aallot tulevat (°).
        var direction: Double
        var period: Double
    }

    let coordinate: CLLocationCoordinate2D
    let timeLabel: String
    var wind: Wind?
    var wave: Wave?
    var onForecast: () -> Void
    var onMakeSpot: () -> Void
    /// Kelivahti tähän pisteeseen (nil = ei kirjautunut → ei näytetä).
    var onAlert: (() -> Void)? = nil
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Ennustepiste")
                        .font(.system(.headline, design: .rounded))
                    Text(timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Tuuli ja aallokko omilla riveillään — yhdellä rivillä arvot rivittyivät rumasti.
                VStack(alignment: .leading, spacing: 2) {
                    if let wind {
                        Label {
                            Text("\(wind.speed, specifier: "%.0f") m/s")
                        } icon: {
                            Image(systemName: "arrow.up")
                                .rotationEffect(.degrees(wind.direction + 180))
                        }
                        .accessibilityLabel("Tuuli \(Int(wind.speed.rounded())) metriä sekunnissa, \(Int(wind.direction)) astetta")
                    }
                    if let wave {
                        Label {
                            Text(wave.period > 0
                                 ? String(format: "%.1f m · %.0f s", wave.height, wave.period)
                                 : String(format: "%.1f m", wave.height))
                        } icon: {
                            Image(systemName: "water.waves")
                        }
                        .accessibilityLabel("Aallot \(String(format: "%.1f", wave.height)) metriä")
                    }
                    if wind == nil && wave == nil {
                        Text("Ei kenttädataa tässä kohdassa")
                    }
                }
                .font(.subheadline.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
                Text(String(format: "%.3f°N %.3f°E", coordinate.latitude, coordinate.longitude))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onForecast) {
                Image(systemName: "wind.circle.fill")
                    .font(.title)
                    .foregroundStyle(.cyan)
            }
            .accessibilityLabel("Näytä ennuste")

            Button(action: onMakeSpot) {
                Image(systemName: "star.circle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
            }
            .accessibilityLabel("Lisää spotti tähän")

            if let onAlert {
                Button(action: onAlert) {
                    Image(systemName: "bell.circle.fill")
                        .font(.title)
                        .foregroundStyle(Theme.wind)
                }
                .accessibilityLabel("Kelivahti tähän pisteeseen")
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Sulje")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}
