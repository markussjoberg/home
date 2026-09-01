import Foundation

/// Hypyn tiedot: hetki, air time ja alastulon voimakkuus.
public struct Jump: Codable, Sendable, Equatable {
    /// Irtoamishetki (s session alusta).
    public var t: TimeInterval
    /// Ilmalento sekunteina.
    public var airTime: TimeInterval
    /// Alastulon huippukiihtyvyys (m/s²) — "kuinka kovaa tultiin alas".
    public var landingG: Double

    public init(t: TimeInterval, airTime: TimeInterval, landingG: Double) {
        self.t = t
        self.airTime = airTime
        self.landingG = landingG
    }
}

/// Hyppyanalyysi sessiolle.
public struct JumpAnalysis: Codable, Sendable, Equatable {
    public var jumps: [Jump]

    public init(jumps: [Jump] = []) {
        self.jumps = jumps
    }

    public var count: Int { jumps.count }
    public var totalAirTime: TimeInterval { jumps.reduce(0) { $0 + $1.airTime } }
    public var longest: Jump? { jumps.max { $0.airTime < $1.airTime } }
}

/// Tunnistaa hypyt (air time) pystykiihtyvyydestä: vapaapudotuksessa anturin
/// kokonaiskiihtyvyys on ~0, jolloin painovoiman suuntainen käyttäjäkiihtyvyys
/// on ~−9,8 m/s². Hyppy = riittävän pitkä yhtenäinen vapaapudotusjakso, jonka
/// päättää alastulon iskupiikki. Ranteen heilautus tuottaa vain lyhyitä
/// pseudopudotuksia — minimikesto suodattaa ne.
public enum JumpDetector {

    public struct Config: Sendable {
        /// Vapaapudotuksen kynnys: pystykiihtyvyys alle tämän (m/s²).
        public var freefallThreshold: Double = -7.0
        /// Pienin ilmalento (s), joka lasketaan hypyksi.
        public var minAirTime: TimeInterval = 0.35
        /// Suurin uskottava ilmalento (s) — pidempi on anturivirhe.
        public var maxAirTime: TimeInterval = 4.0
        /// Alastulon iskun minimikiihtyvyys (m/s²) ikkunassa pudotuksen jälkeen.
        public var minLandingImpact: Double = 4.0
        /// Ikkuna (s), jolta alastulon isku haetaan.
        public var landingWindow: TimeInterval = 0.6
        /// Lyhyt katkos vapaapudotuksessa, joka siedetään (anturikohina, s).
        public var dropoutTolerance: TimeInterval = 0.08

        public init() {}
    }

    public static func analyze(_ samples: [MotionSample], config: Config = Config()) -> JumpAnalysis {
        guard samples.count > 4 else { return JumpAnalysis() }
        var jumps: [Jump] = []

        var freefallStart: TimeInterval?
        var lastFreefall: TimeInterval?

        func closeFreefall(endingAt end: TimeInterval, index: Int) {
            defer { freefallStart = nil; lastFreefall = nil }
            guard let start = freefallStart else { return }
            let airTime = end - start
            guard airTime >= config.minAirTime, airTime <= config.maxAirTime else { return }
            // Alastulon isku: suurin positiivinen piikki heti pudotuksen jälkeen.
            var impact = 0.0
            var i = index
            while i < samples.count, samples[i].t - end <= config.landingWindow {
                impact = max(impact, samples[i].verticalAcceleration)
                i += 1
            }
            guard impact >= config.minLandingImpact else { return }
            jumps.append(Jump(t: start, airTime: airTime, landingG: impact))
        }

        for (index, sample) in samples.enumerated() {
            if sample.verticalAcceleration <= config.freefallThreshold {
                if freefallStart == nil { freefallStart = sample.t }
                lastFreefall = sample.t
            } else if let last = lastFreefall {
                if sample.t - last > config.dropoutTolerance {
                    closeFreefall(endingAt: last, index: index)
                }
            }
        }
        if let last = lastFreefall {
            closeFreefall(endingAt: last, index: samples.count - 1)
        }

        return JumpAnalysis(jumps: jumps)
    }
}
