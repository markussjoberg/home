import Foundation

/// Yhteiset esitysmuodot kellolle ja puhelimelle.
public enum Format {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// m/s → "23,4 km/h"
    public static func speedKmh(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", metersPerSecond * 3.6).replacingOccurrences(of: ".", with: ",")
    }

    /// "8,2 m/s"
    public static func speedMs(_ metersPerSecond: Double) -> String {
        String(format: "%.1f m/s", metersPerSecond).replacingOccurrences(of: ".", with: ",")
    }

    public static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "%.0f m", meters)
    }

    public static func percent(_ fraction: Double) -> String {
        String(format: "%.0f %%", fraction * 100)
    }
}
