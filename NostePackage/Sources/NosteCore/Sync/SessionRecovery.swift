import Foundation

/// Kesken jääneen session levytallennus (kaatumissuoja). Sama mekanismi kellossa
/// ja puhelimessa: sessio talletetaan ajon aikana 30 s välein, ja jos appi kuolee,
/// seuraava käynnistys rakentaa yhteenvedon talletetusta datasta.
public enum SessionRecovery {

    public struct State: Codable, Sendable {
        public var sport: Sport
        public var startDate: Date
        public var points: [TrackPoint]
        public var strokeTimes: [TimeInterval]
        public var heartRate: [HeartRateSample]?
        /// Segmentit autosaven hetkeen asti (vanha talletus: nil = kaikki vettä).
        public var segments: [SessionSegment]?

        public init(sport: Sport, startDate: Date, points: [TrackPoint],
                    strokeTimes: [TimeInterval], heartRate: [HeartRateSample]? = nil,
                    segments: [SessionSegment]? = nil) {
            self.sport = sport
            self.startDate = startDate
            self.points = points
            self.strokeTimes = strokeTimes
            self.heartRate = heartRate
            self.segments = segments
        }
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session-recovery.json")
    }

    public static func save(_ state: State) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func load() -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Rakentaa yhteenvedon talletetusta tilasta (pumput talletetuista
    /// pumppuhetkistä, koska raakasignaalia ei enää ole).
    public static func summarize(_ state: State) -> SessionSummary {
        var summary = SessionAnalyzer.summarize(
            sport: state.sport,
            startDate: state.startDate,
            points: state.points,
            heartRate: state.heartRate ?? [],
            segments: state.segments
        )
        if state.sport.countsPumps {
            // Vain vesijaksojen pumput (siirtymän tärinä ei ole pumppausta).
            let strokes: [TimeInterval]
            if let segments = state.segments, segments.contains(where: { $0.kind != .water }) {
                let windows = segments.filter { $0.kind == .water }
                strokes = state.strokeTimes.filter { t in
                    windows.contains { t >= $0.start && t <= $0.end }
                }
            } else {
                strokes = state.strokeTimes
            }
            let pumps = PumpDetector.analysis(fromStrokeTimes: strokes)
            summary.pumps = pumps
            // Suorituskohtaiset pumppumäärät talletetuista pumppuhetkistä.
            if !summary.rides.segments.isEmpty {
                summary.flights = FlightDetail.compute(
                    segments: summary.rides.segments,
                    points: state.points,
                    strokeTimes: strokes,
                    maxPlausibleSpeed: state.sport.maxPlausibleSpeed,
                    bouts: pumps.bouts
                )
            }
        }
        return summary
    }
}
