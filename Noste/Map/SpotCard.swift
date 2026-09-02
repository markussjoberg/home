import SwiftUI
import NosteCore

/// Oman spotin pikakortti kartalla: napautus avaa spotin sää- ja infosivun,
/// jonka takana muokkaus on — editori ei aukea vahingossa.
struct SpotCard: View {
    let spot: SpotData
    var onOpen: () -> Void
    var onClose: () -> Void

    private static let compassNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                cardBody
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spot.name.isEmpty ? "Nimetön spotti" : spot.name), avaa sää ja tiedot")

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

    private var cardBody: some View {
        HStack(spacing: 12) {
            if let exposure = spot.exposureByOctant, exposure.count == 8 {
                ExposureRoseGlyph(exposure: exposure, diameter: 40)
                    .frame(width: 46, height: 46)
            } else {
                Image(systemName: spot.isFavorite ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name.isEmpty ? "Nimetön spotti" : spot.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Text(conditionsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// Spotin yleistieto: vesistö, toimivat suunnat ja voimakkuusrajat.
    private var conditionsText: String {
        var parts: [String] = [spot.waterType.displayName]
        if let directions = spot.goodDirections, !directions.isEmpty {
            parts.append(directions.map { Self.compassNames[$0] }.joined(separator: " "))
        }
        switch (spot.minWind, spot.maxWind) {
        case let (min?, max?): parts.append("\(Int(min))–\(Int(max)) m/s")
        case let (min?, nil): parts.append("≥ \(Int(min)) m/s")
        case let (nil, max?): parts.append("≤ \(Int(max)) m/s")
        default: break
        }
        if !spot.sports.isEmpty { parts.append(spot.sports.map(\.displayName).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
