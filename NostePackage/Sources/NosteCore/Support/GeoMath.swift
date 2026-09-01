import Foundation

public enum GeoMath {
    /// Haversine-etäisyys metreinä.
    public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Suuntima asteina (0 = pohjoinen, myötäpäivään).
    public static func bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Tuulen/kulkusuunnan nimi kahdeksalla ilmansuunnalla.
    /// Suuntien lyhin kulmaero (0–180°).
    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    /// Etumerkillinen kulmamuutos suunnasta toiseen (−180…180°, + = myötäpäivään).
    public static func signedAngleDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    public static func compassName(degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % 8
        return names[(index + 8) % 8]
    }
}
