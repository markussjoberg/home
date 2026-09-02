import SwiftUI

/// Kahdeksanosainen kompassiruusu: sektori napautetaan päälle/pois. Korvaa
/// N/NE/E-palikat — suunnat hahmottuvat kartan tapaan, ei listana.
struct CompassRoseSelector: View {
    /// Valitut ilmansuuntaindeksit 0–7 (0 = N, 45° välein), nil = ei valintaa.
    @Binding var selected: [Int]?
    var diameter: CGFloat = 210

    private static let shortNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private static let longNames = ["pohjoinen", "koillinen", "itä", "kaakko", "etelä", "lounas", "länsi", "luode"]

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let isOn = selected?.contains(index) == true
                Button {
                    toggle(index)
                } label: {
                    Wedge(index: index)
                        .fill(isOn ? Color.accentColor : Color(.systemGray5))
                        .overlay(Wedge(index: index).stroke(Color(.systemBackground), lineWidth: 2))
                        .overlay {
                            Text(Self.shortNames[index])
                                .font(.caption.weight(isOn ? .bold : .regular))
                                .foregroundStyle(isOn ? .white : .primary)
                                .offset(labelOffset(index))
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Wedge(index: index))
                .accessibilityLabel(Self.longNames[index].capitalized)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            // Keskiö: mistä tuulee → nuoli kertoo lukusuunnan.
            Circle()
                .fill(Color(.systemBackground))
                .frame(width: diameter * 0.34, height: diameter * 0.34)
            VStack(spacing: 0) {
                Image(systemName: "wind")
                    .font(.footnote)
                Text("mistä\ntuulee")
                    .font(.system(size: 9))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .contain)
    }

    private func toggle(_ index: Int) {
        var directions = selected ?? []
        if let position = directions.firstIndex(of: index) {
            directions.remove(at: position)
        } else {
            directions.append(index)
        }
        selected = directions.isEmpty ? nil : directions.sorted()
    }

    private func labelOffset(_ index: Int) -> CGSize {
        let angle = Double(index) * 45 * .pi / 180
        let r = diameter * 0.36
        return CGSize(width: sin(angle) * r, height: -cos(angle) * r)
    }

    /// Yksi 45° sektori renkaasta (sisäsäde 0,18, ulkosäde 0,5 kehyksestä).
    struct Wedge: Shape {
        let index: Int

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * 0.36
            // Sektori keskittyy suuntaansa: N = -90° ± 22,5°.
            let start = Angle.degrees(-90 + Double(index) * 45 - 22.5)
            let end = Angle.degrees(-90 + Double(index) * 45 + 22.5)
            var path = Path()
            path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
            return path
        }
    }
}
