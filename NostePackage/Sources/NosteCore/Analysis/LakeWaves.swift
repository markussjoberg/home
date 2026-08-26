import Foundation

/// Järviaaltojen arvio fetch-rajoitteisella JONSWAP-kaavalla (Hasselmann).
/// Merillä käytetään aaltomallia (Open-Meteo Marine); järville lasketaan
/// tuulesta ja pyyhkäisymatkasta:
///
///     F̂  = g·F / U²          (dimensioton fetch)
///     Hs = 0,0016·√F̂ · U²/g  (merkitsevä aallonkorkeus)
///     Tp = 0,286·F̂^⅓ · U/g   (huippuperiodi)
///
/// Korkeus katkaistaan täysin kehittyneen merenkäynnin tasoon
/// (Pierson–Moskowitz, Hs ≤ 0,21·U²/g). Fetch saadaan spotin
/// maastoanalyysistä (palvelimen korkeusprofiilit ilmansuunnittain).
public enum LakeWaves {

    public struct Estimate: Equatable, Sendable {
        /// Merkitsevä aallonkorkeus (m).
        public var height: Double
        /// Huippuperiodi (s).
        public var period: Double
    }

    private static let g = 9.81

    public static func estimate(windSpeed: Double, fetchMeters: Double) -> Estimate {
        guard windSpeed > 0, fetchMeters > 0 else {
            return Estimate(height: 0, period: 0)
        }
        let dimensionlessFetch = g * fetchMeters / (windSpeed * windSpeed)
        var height = 0.0016 * dimensionlessFetch.squareRoot() * windSpeed * windSpeed / g
        let period = 0.286 * pow(dimensionlessFetch, 1.0 / 3.0) * windSpeed / g
        height = min(height, 0.21 * windSpeed * windSpeed / g)
        return Estimate(height: height, period: period)
    }

    /// Arvio ennustetunnille spotin fetch-datan pohjalta: fetch valitaan tuulen
    /// tulosuunnan ilmansuunnalta. nil jos fetchiä ei ole (maastoanalyysi
    /// tekemättä) tai se on mitätön.
    public static func estimate(for hour: WindHour, fetchKmByOctant: [Double]?) -> Estimate? {
        guard let fetchKmByOctant, fetchKmByOctant.count == 8 else { return nil }
        let fetchKm = fetchKmByOctant[SpotData.compassOctant(degrees: hour.direction)]
        guard fetchKm >= 0.25 else { return nil }
        return estimate(windSpeed: hour.speed, fetchMeters: fetchKm * 1000)
    }
}
