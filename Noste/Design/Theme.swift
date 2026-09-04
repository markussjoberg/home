import SwiftUI

/// Nosten ilme: tumma ensin (Dawn Patrol -henkinen), meri-navy pohja, syaani
/// tuulelle, oranssi foilille/lennoille. Isot pyöristetyt numerot — luvut
/// ovat appin sisältö, teksti selittää.
enum Theme {
    static let background = Color(red: 0.05, green: 0.08, blue: 0.14)
    static let surface = Color(red: 0.10, green: 0.14, blue: 0.22)
    static let surfaceElevated = Color(red: 0.14, green: 0.19, blue: 0.29)
    static let wind = Color(red: 0.39, green: 0.82, blue: 1.00)
    static let ride = Color(red: 1.00, green: 0.62, blue: 0.25)
    static let ok = Color(red: 0.36, green: 0.86, blue: 0.55)
    static let muted = Color.white.opacity(0.55)

    static let cardRadius: CGFloat = 18
}

extension Font {
    /// Iso mittariluku (nopeus, kesto, tuuli).
    static func stat(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static var statLabel: Font { .system(.caption, design: .rounded).weight(.medium) }
    static var cardTitle: Font { .system(.title3, design: .rounded).weight(.bold) }
}

/// Kortti: yhtenäinen tausta ja pyöristys listoille ja paneeleille.
struct CardBackground: ViewModifier {
    var elevated = false
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(elevated ? Theme.surfaceElevated : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension View {
    func card(elevated: Bool = false) -> some View { modifier(CardBackground(elevated: elevated)) }

    /// Listarivi korttina: ei erotinta, läpinäkyvä rivitausta, väli riveihin.
    func cardRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Tilastolaatta: iso luku, pieni selite, valinnainen väri.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .white
    var size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.stat(size))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: size * 1.25, alignment: .bottomLeading) // kutistuva luku ei siirrä selitettä
            Text(label)
                .font(.statLabel)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tuulinuoli + nopeus yhtenä yksikkönä (mistä tuulee → nuoli osoittaa minne).
struct WindGlyph: View {
    let speed: Double
    let gust: Double?
    let direction: Double
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.6, weight: .bold))
                .rotationEffect(.degrees(direction + 180))
                .foregroundStyle(Theme.wind)
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.0f", speed))
                    .font(.stat(size))
                    .monospacedDigit()
                + Text(" m/s").font(.statLabel).foregroundStyle(Theme.muted)
                if let gust {
                    Text("puuskat \(String(format: "%.0f", gust))")
                        .font(.statLabel)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}
