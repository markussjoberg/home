import SwiftUI
import NosteCore

/// Tuuliarvosanan valitsin: 1–5 tähteä tai "Ei riittänyt".
struct RatingControl: View {
    var rating: WindRating?
    var onSelect: (WindRating) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        onSelect(WindRating(rawValue: star)!)
                    } label: {
                        Image(systemName: star <= (rating?.rawValue ?? 0) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) tähteä")
                }
            }
            Button {
                onSelect(.insufficient)
            } label: {
                Text("Ei riittänyt")
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(rating == .insufficient ? Color.orange : Color(.systemGray5), in: Capsule())
                    .foregroundStyle(rating == .insufficient ? .black : .primary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Pieni tähtimerkintä listoihin ja ennusteriveille (esim. "★ 4,1").
struct StarBadge: View {
    let value: Double
    var highlight = true

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.caption2)
            Text(String(format: "%.1f", value).replacingOccurrences(of: ".", with: ","))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(highlight && value >= 3.5 ? .green : .secondary)
    }
}
