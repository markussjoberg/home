import Foundation

/// Tunnistaa pump foil -pumppaukset pystykiihtyvyydestä.
///
/// Menetelmä: signaali tasoitetaan vähentämällä liukuva keskiarvo (poistaa aallokon
/// keinunnan ja hitaan ryömin), minkä jälkeen lasketaan huippu–pohja-vuorottelu
/// hystereesikaistalla. Pumpuksi lasketaan POHJA (alaspäin menevä työntö) —
/// kenttätesti 2026-09: ranteen signaalissa yksi fyysinen pumppu tuottaa sekä
/// ylä- että alapiikin, ja huippujen laskenta tuplasi määrän koettuun nähden.
/// Pohjan amplitudin edellisestä huipusta pitää riittää, eikä pumppu saa tulla
/// liian nopeasti edellisen perään. Toimii virtaavasti (näyte kerrallaan),
/// joten sama koodi käy kellossa liveksi ja jälkianalyysiin.
public final class PumpDetector {

    public struct Config: Sendable {
        /// Liukuvan keskiarvon ikkuna sekunteina (pidempi kuin pumppusykli).
        public var detrendWindow: TimeInterval = 3.0
        /// Suunnanvaihdon vahvistuskaista (m/s²).
        public var hysteresis: Double = 1.0
        /// Vaadittu huippu–pohja-amplitudi (m/s²), jotta pohja lasketaan pumpuksi.
        public var minAmplitude: Double = 2.5
        /// Kahden pumpun minimiväli sekunteina (~max 90 pumppua/min) — hylkää
        /// saman pumpun jälkiheilahduksen.
        public var minStrokeInterval: TimeInterval = 0.65
        /// Suurin pumppujen väli, jolla ne kuuluvat samaan pumppausjaksoon.
        public var boutGap: TimeInterval = 2.5

        public init() {}
    }

    private enum Direction { case unknown, up, down }

    private let config: Config
    private var window: [(t: TimeInterval, v: Double)] = []
    private var windowSum: Double = 0

    private var direction: Direction = .unknown
    private var candidateMax: (t: TimeInterval, v: Double)?
    private var candidateMin: (t: TimeInterval, v: Double)?
    private var lastPeakValue: Double = 0
    private var strokeTimes: [TimeInterval] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Tähän mennessä laskettujen pumppujen määrä (live-näyttöä varten).
    public var strokeCount: Int { strokeTimes.count }

    public func add(_ sample: MotionSample) {
        // Liukuva keskiarvo aikaikkunalla.
        window.append((sample.t, sample.verticalAcceleration))
        windowSum += sample.verticalAcceleration
        while let first = window.first, sample.t - first.t > config.detrendWindow {
            windowSum -= first.v
            window.removeFirst()
        }
        let mean = windowSum / Double(window.count)
        let x = sample.verticalAcceleration - mean
        let t = sample.t

        switch direction {
        case .unknown:
            if candidateMax == nil || x > candidateMax!.v { candidateMax = (t, x) }
            if candidateMin == nil || x < candidateMin!.v { candidateMin = (t, x) }
            if let mx = candidateMax, x < mx.v - config.hysteresis {
                direction = .down
                lastPeakValue = mx.v
                candidateMin = (t, x)
            } else if let mn = candidateMin, x > mn.v + config.hysteresis {
                direction = .up
                candidateMax = (t, x)
            }
        case .up:
            if x > (candidateMax?.v ?? -.infinity) { candidateMax = (t, x) }
            if let mx = candidateMax, x < mx.v - config.hysteresis {
                lastPeakValue = mx.v
                direction = .down
                candidateMin = (t, x)
            }
        case .down:
            if x < (candidateMin?.v ?? .infinity) { candidateMin = (t, x) }
            if let mn = candidateMin, x > mn.v + config.hysteresis {
                // Pohja vahvistui — alaspäin menevä työntö on pumppu, jos
                // amplitudi edellisestä huipusta ja väli riittävät.
                let amplitude = lastPeakValue - mn.v
                let sinceLast = strokeTimes.last.map { mn.t - $0 } ?? .infinity
                if amplitude >= config.minAmplitude && sinceLast >= config.minStrokeInterval {
                    strokeTimes.append(mn.t)
                }
                direction = .up
                candidateMax = (t, x)
            }
        }
    }

    public func finish() -> PumpAnalysis {
        Self.analysis(fromStrokeTimes: strokeTimes, config: config)
    }

    /// Rakentaa analyysin pelkistä pumppuhetkistä — käytetään myös kaatumisesta
    /// palautumiseen, jossa raakasignaalia ei enää ole mutta pumppuhetket on talletettu.
    public static func analysis(fromStrokeTimes strokeTimes: [TimeInterval], config: Config = Config()) -> PumpAnalysis {
        var bouts: [RideSegment] = []
        var boutStart: TimeInterval?
        var boutStrokes = 0
        var previous: TimeInterval?
        var activeTime: TimeInterval = 0
        var activeStrokes = 0

        func closeBout(endingAt end: TimeInterval) {
            guard let start = boutStart, boutStrokes >= 2 else { boutStart = nil; boutStrokes = 0; return }
            bouts.append(RideSegment(start: start, end: end, distance: 0))
            activeTime += end - start
            activeStrokes += boutStrokes
            boutStart = nil
            boutStrokes = 0
        }

        for t in strokeTimes {
            if let prev = previous, t - prev > config.boutGap {
                closeBout(endingAt: prev)
            }
            if boutStart == nil { boutStart = t }
            boutStrokes += 1
            previous = t
        }
        if let prev = previous { closeBout(endingAt: prev) }

        let cadence = activeTime > 0 ? Double(activeStrokes - bouts.count) / activeTime * 60 : 0
        return PumpAnalysis(
            strokeCount: strokeTimes.count,
            strokeTimes: strokeTimes,
            averageCadence: max(0, cadence),
            bouts: bouts
        )
    }

    /// Tähän mennessä havaitut pumppuhetket (autosavea varten).
    public var currentStrokeTimes: [TimeInterval] { strokeTimes }

    /// Jälkianalyysi valmiille näytelistalle.
    public static func analyze(_ samples: [MotionSample], config: Config = Config()) -> PumpAnalysis {
        let detector = PumpDetector(config: config)
        for sample in samples { detector.add(sample) }
        return detector.finish()
    }
}
