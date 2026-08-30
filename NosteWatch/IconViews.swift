import SwiftUI
import NosteCore

/// Nosten oma ikonisetti: template-PDF:t asset-katalogissa, sama viivakieli
/// kuin appi-ikonissa. Värjäytyvät foregroundStylella kuin SF Symbolit.
extension Sport {
    var icon: Image { Image(assetName) }
}

extension GearType {
    var icon: Image { Image(assetName) }
}

/// Ikoni kiinteään kokoon (Labelin ikonipaikkaan tms.).
struct SportIcon: View {
    let sport: Sport
    var size: CGFloat = 22

    var body: some View {
        sport.icon
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

struct GearIcon: View {
    let type: GearType
    var size: CGFloat = 22

    var body: some View {
        type.icon
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
