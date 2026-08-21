import Foundation

/// Tunnistaa pump foil -pumppaukset pystykiihtyvyydestä.
///
/// Menetelmä: signaali tasoitetaan vähentämällä liukuva keskiarvo (poistaa aallokon
/// keinunnan ja hitaan ryömin), minkä jälkeen lasketaan huippu–pohja-vuorottelu
/// hystereesikaistalla. Pumpuksi lasketaan huippu, jonka amplitudi edellisestä
/// pohjasta on riittävä ja joka ei tule liian nopeasti edellisen pumpun perään.
/// Toimii virtaavasti (näyte kerrallaan), joten sama koodi käy kellossa liveksi
/// ja jälkianalyysiin.
public final class PumpDetector {

    public struct Config: Sendable {
        /// Liukuvan keskiarvon ikkuna sekunteina (pidempi kuin pumppusykli).
        public var detrendWindow: TimeInterval = 3.0
        /// Suunnanvaihdon vahvistuskaista (m/s²).
        public var hysteresis: Double = 1.0
        /// Vaadittu huippu–pohja-amplitudi (m/s²), jotta huippu lasketaan pumpuksi.
        public var minAmplitude: Double = 2.5
        /// Kahden pumpun minimiväli sekunteina (~max 130 pumppua/min).
        public var minStrokeInterval: TimeInterval = 0.45
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
    private var lastTroughValue: Double = 0
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
                lastTroughValue = x
                candidateMin = (t, x)
            } else if let mn = candidateMin, x > mn.v + config.hysteresis {
                direction = .up
                lastTroughValue = mn.v
                candidateMax = (t, x)
            }
        case .up:
            if x > (candidateMax?.v ?? -.infinity) { candidateMax = (t, x) }
            if let mx = candidateMax, x < mx.v - config.hysteresis {
                // Huippu vahvistui: laske pumpuksi jos amplitudi ja väli riittävät.
                let amplitude = mx.v - lastTroughValue
                let sinceLast = strokeTimes.last.map { mx.t - $0 } ?? .infinity
                if amplitude >= config.minAmplitude && sinceLast >= config.minStrokeInterval {
                    strokeTimes.append(mx.t)
                }
                direction = .down
                candidateMin = (t, x)
            }
        case .down:
            if x < (candidateMin?.v ?? .infinity) { candidateMin = (t, x) }
            if let mn = candidateMin, x > mn.v + config.hysteresis {
                lastTroughValue = mn.v
                direction = .up
                candidateMax = (t, x)
            }
        }
    }

    public func finish() -> PumpAnalysis {
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

    /// Jälkianalyysi valmiille näytelistalle.
    public static func analyze(_ samples: [MotionSample], config: Config = Config()) -> PumpAnalysis {
        let detector = PumpDetector(config: config)
        for sample in samples { detector.add(sample) }
        return detector.finish()
    }
}
