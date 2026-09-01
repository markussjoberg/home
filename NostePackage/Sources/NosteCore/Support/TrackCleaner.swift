import Foundation

/// Siivoaa GPS-jäljen NÄYTTÖÄ varten: häiriöpisteet (villit fixit esim. veden
/// alta noustessa) piirtyisivät pitkinä suorina piikkeinä. Piste hylätään,
/// jos siirtymä edellisestä hyväksytystä pisteestä vaatisi epäuskottavan
/// nopeuden. Raakadataan ei kosketa — analyysi suodattaa omat lukunsa itse.
public enum TrackCleaner {

    public static func clean(_ points: [TrackPoint], maxPlausibleSpeed: Double) -> [TrackPoint] {
        guard points.count > 2 else { return points }
        // Reilu katto: hetkellinen GPS-heitto sallitaan, teleportti ei.
        let cap = max(maxPlausibleSpeed * 1.5, 12)

        func impliedSpeed(_ a: TrackPoint, _ b: TrackPoint) -> Double {
            let dt = b.t - a.t
            guard dt > 0 else { return .infinity }
            return GeoMath.distanceMeters(lat1: a.latitude, lon1: a.longitude,
                                          lat2: b.latitude, lon2: b.longitude) / dt
        }

        // Ankkuri: ensimmäinen piste, jonka seuraaja vahvistaa — villi
        // alkufix ei saa vetää koko jälkeä mukanaan.
        var startIndex = 0
        while startIndex + 1 < points.count,
              impliedSpeed(points[startIndex], points[startIndex + 1]) > cap {
            startIndex += 1
        }

        var cleaned: [TrackPoint] = [points[startIndex]]
        for point in points[(startIndex + 1)...] {
            let badAccuracy = point.horizontalAccuracy >= 0 && point.horizontalAccuracy > 60
            if !badAccuracy, impliedSpeed(cleaned[cleaned.count - 1], point) <= cap {
                cleaned.append(point)
            }
        }
        return cleaned
    }
}
