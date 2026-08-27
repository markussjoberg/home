import Foundation

/// GPX 1.1 -vienti: sessio ulos muihin palveluihin (Strava tms.) tai talteen.
public enum GPXExporter {

    public static func gpx(track: [TrackPoint], startDate: Date, name: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="Noste" xmlns="http://www.topografix.com/GPX/1/1">"#)
        lines.append("  <trk>")
        lines.append("    <name>\(escape(name))</name>")
        lines.append("    <trkseg>")
        for point in track {
            let time = formatter.string(from: startDate.addingTimeInterval(point.t))
            lines.append(String(
                format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"><time>%@</time></trkpt>",
                point.latitude, point.longitude, time
            ))
        }
        lines.append("    </trkseg>")
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
