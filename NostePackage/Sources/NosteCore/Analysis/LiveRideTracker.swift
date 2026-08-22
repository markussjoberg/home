import Foundation

/// Live-foilitila kellon mittarinäkymään: nykyisen lennon kesto, lentojen määrä ja
/// kumulatiivinen foiliaika session aikana. Sama nopeushystereesi kuin
/// jälkianalyysin RideSegmenterissä, mutta virtaavana tilakoneena.
///
/// Lento lasketaan lentojen määrään vasta kun se on kestänyt minimikeston —
/// näin aallonpohjan heilahdus ei kilahda laskuriin. Kumulatiivinen aika
/// kertyy silti heti, jotta iso foiliaikamittari ei nyki.
public final class LiveRideTracker {

    public struct State: Equatable, Sendable {
        public var isRiding: Bool
        /// Nykyisen lennon kesto (0 jos ei lennossa).
        public var currentRideDuration: TimeInterval
        /// Valmiiden, minimikeston ylittäneiden lentojen määrä (sisältää käynnissä olevan heti kun se ylittää minimin).
        public var rideCount: Int
        /// Kumulatiivinen aika foililla.
        public var totalRideTime: TimeInterval

        public init(isRiding: Bool = false, currentRideDuration: TimeInterval = 0, rideCount: Int = 0, totalRideTime: TimeInterval = 0) {
            self.isRiding = isRiding
            self.currentRideDuration = currentRideDuration
            self.rideCount = rideCount
            self.totalRideTime = totalRideTime
        }
    }

    private let takeoffSpeed: Double
    private let touchdownSpeed: Double
    private let minDuration: TimeInterval

    private var rideStart: TimeInterval?
    private var countedCurrentRide = false
    private var lastTime: TimeInterval?
    private var state = State(isRiding: false, currentRideDuration: 0, rideCount: 0, totalRideTime: 0)

    public init(sport: Sport) {
        takeoffSpeed = sport.takeoffSpeed
        touchdownSpeed = sport.touchdownSpeed
        minDuration = sport == .pumpFoil ? 2 : 3
    }

    /// Syötä GPS-päivitys (aika session alusta, nopeus m/s; nopeus < 0 = ei tiedossa).
    @discardableResult
    public func add(t: TimeInterval, speed: Double) -> State {
        defer { lastTime = t }

        if let start = rideStart {
            // Lennossa: kerrytä aikaa edellisestä päivityksestä.
            if let last = lastTime, t > last {
                state.totalRideTime += t - last
            }
            state.currentRideDuration = t - start
            if !countedCurrentRide && state.currentRideDuration >= minDuration {
                state.rideCount += 1
                countedCurrentRide = true
            }
            if speed >= 0 && speed < touchdownSpeed {
                rideStart = nil
                countedCurrentRide = false
                state.isRiding = false
                state.currentRideDuration = 0
            }
        } else if speed >= takeoffSpeed {
            rideStart = t
            countedCurrentRide = false
            state.isRiding = true
            state.currentRideDuration = 0
        }
        return state
    }

    public var current: State { state }
}
