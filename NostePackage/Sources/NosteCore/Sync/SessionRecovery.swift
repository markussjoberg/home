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

        public init(sport: Sport, startDate: Date, points: [TrackPoint],
                    strokeTimes: [TimeInterval], heartRate: [HeartRateSample]? = nil) {
            self.sport = sport
            self.startDate = startDate
            self.points = points
            self.strokeTimes = strokeTimes
            self.heartRate = heartRate
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
            heartRate: state.heartRate ?? []
        )
        if state.sport.countsPumps {
            summary.pumps = PumpDetector.analysis(fromStrokeTimes: state.strokeTimes)
        }
        return summary
    }
}
