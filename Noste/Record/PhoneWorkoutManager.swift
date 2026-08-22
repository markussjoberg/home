import Foundation
import Combine
import CoreMotion
import CoreLocation
import UIKit
import NosteCore

/// Session tallennus puhelimella — kaverit ilman kelloa (tai kännykkä liivissä)
/// saavat samat mittarit. Sama analytiikka, autopaussi ja kaatumissuoja kuin
/// kellossa; syke ja HealthKit-treeni puuttuvat (ei anturia).
@MainActor
final class PhoneWorkoutManager: NSObject, ObservableObject {

    enum Phase {
        case idle
        case running
        case paused
        case ended
    }

    @Published var phase: Phase = .idle
    @Published var sport: Sport = .wingFoil
    @Published var elapsed: TimeInterval = 0
    @Published var currentSpeed: Double = 0
    @Published var liveDistance: Double = 0
    @Published var livePumpCount: Int = 0
    @Published var rideState = LiveRideTracker.State()
    @Published var summary: SessionSummary?
    @Published var trackForSummary: [TrackPoint] = []
    @Published var isAutoPaused = false
    @Published var notice: String?

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    private var startDate = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var timer: AnyCancellable?
    private var ticksSinceAutosave = 0

    private var trackPoints: [TrackPoint] = []
    private let motionLock = NSLock()
    private var motionSamples: [MotionSample] = []
    private var pumpDetector = PumpDetector()
    private var rideTracker = LiveRideTracker(sport: .wingFoil)
    private var autoPause = AutoPauseController(sport: .wingFoil)
    private var lastGoodLocation: CLLocation?
    private var startAnchor: CLLocation?

    /// Kesken jäänyt sessio edellisestä käynnistyksestä (näytetään talletettavaksi).
    @Published var recoveredPayload: WatchSync.SessionPayload?

    override init() {
        super.init()
        if let state = SessionRecovery.load() {
            SessionRecovery.clear()
            if state.points.count >= 2 {
                recoveredPayload = WatchSync.SessionPayload(
                    summary: SessionRecovery.summarize(state),
                    track: state.points
                )
            }
        }
    }

    func start(sport: Sport) {
        guard phase == .idle else { return }
        self.sport = sport
        summary = nil
        notice = nil
        trackPoints = []
        motionLock.lock(); motionSamples = []; pumpDetector = PumpDetector(); motionLock.unlock()
        rideTracker = LiveRideTracker(sport: sport)
        rideState = rideTracker.current
        autoPause = AutoPauseController(sport: sport)
        isAutoPaused = false
        livePumpCount = 0
        liveDistance = 0
        currentSpeed = 0
        lastGoodLocation = nil
        startAnchor = nil
        pausedTotal = 0
        pausedAt = nil
        startDate = Date()
        ticksSinceAutosave = 0

        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()

        startMotion()
        startTimer()
        UIApplication.shared.isIdleTimerDisabled = true

        phase = .running
    }

    func pause() {
        guard phase == .running else { return }
        beginPause(automatic: false)
        locationManager.stopUpdatingLocation()
        autoPause.manualPause(t: Date().timeIntervalSince(startDate))
    }

    func resume() {
        guard phase == .paused else { return }
        autoPause.manualResume()
        endPause()
        locationManager.startUpdatingLocation()
    }

    func end() {
        guard phase == .running || phase == .paused else { return }
        if phase == .paused, let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        phase = .ended
        isAutoPaused = false
        timer?.cancel()
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        UIApplication.shared.isIdleTimerDisabled = false

        motionLock.lock()
        let motion = motionSamples
        motionLock.unlock()

        summary = SessionAnalyzer.summarize(sport: sport, startDate: startDate, points: trackPoints, motion: motion)
        trackForSummary = trackPoints
        SessionRecovery.clear()
    }

    func reset() {
        phase = .idle
        summary = nil
        elapsed = 0
        currentSpeed = 0
        notice = nil
    }

    // MARK: - Paussit (sama malli kuin kellossa)

    private func beginPause(automatic: Bool) {
        phase = .paused
        isAutoPaused = automatic
        pausedAt = Date()
        currentSpeed = 0
        motionManager.stopDeviceMotionUpdates()
    }

    private func endPause() {
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        isAutoPaused = false
        startMotion()
        phase = .running
    }

    private func handleAutoPauseEvent(_ event: AutoPauseController.Event) {
        switch event {
        case .none:
            break
        case .pause(let nearStart):
            guard phase == .running else { break }
            beginPause(automatic: true)
            notice = nearStart
                ? "Autopaussi lähtöpaikalla — jatka, jos sessio jatkuu."
                : "Autopaussi — liike jatkaa automaattisesti."
        case .resume:
            guard phase == .paused, isAutoPaused else { break }
            endPause()
            notice = nil
        case .endSession(let reason):
            guard phase == .paused || phase == .running else { break }
            notice = reason == .drivingDetected
                ? "Sessio päätettiin: liikkumisnopeus ei ollut enää lajille mahdollinen (autoilu?)."
                : "Sessio päätettiin: paussi kesti yli 20 minuuttia."
            end()
        }
    }

    private func startTimer() {
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.phase == .running else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate) - self.pausedTotal
            self.motionLock.lock()
            self.livePumpCount = self.pumpDetector.strokeCount
            self.motionLock.unlock()

            self.ticksSinceAutosave += 1
            if self.ticksSinceAutosave >= 30 {
                self.ticksSinceAutosave = 0
                self.motionLock.lock()
                let strokes = self.pumpDetector.currentStrokeTimes
                self.motionLock.unlock()
                SessionRecovery.save(SessionRecovery.State(
                    sport: self.sport,
                    startDate: self.startDate,
                    points: self.trackPoints,
                    strokeTimes: strokes
                ))
            }
        }
    }

    fileprivate func handle(locations: [CLLocation]) {
        guard phase == .running || (phase == .paused && isAutoPaused) else { return }
        for location in locations {
            let t = location.timestamp.timeIntervalSince(startDate)
            guard t >= 0 else { continue }
            let speed = location.speed
            let accurate = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 30
            if accurate && startAnchor == nil {
                startAnchor = location
            }

            if phase == .running {
                trackPoints.append(TrackPoint(
                    t: t,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    speed: speed,
                    horizontalAccuracy: location.horizontalAccuracy
                ))
                currentSpeed = max(0, speed)
                if accurate {
                    if let previous = lastGoodLocation, max(0, speed) >= 1.0 {
                        liveDistance += location.distance(from: previous)
                    }
                    lastGoodLocation = location
                }
                rideState = rideTracker.add(t: t, speed: speed)
            }

            let distanceFromStart = startAnchor.map { location.distance(from: $0) } ?? -1
            handleAutoPauseEvent(autoPause.add(t: t, speed: speed, distanceFromStart: distanceFromStart))
            if phase == .ended { return }
        }
    }

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        let start = startDate
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let ua = motion.userAcceleration
            let magnitude = max(1e-6, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
            let vertical = (ua.x * g.x + ua.y * g.y + ua.z * g.z) / magnitude * 9.81
            let sample = MotionSample(t: Date().timeIntervalSince(start), verticalAcceleration: vertical)
            self.motionLock.lock()
            self.motionSamples.append(sample)
            self.pumpDetector.add(sample)
            self.motionLock.unlock()
        }
    }
}

extension PhoneWorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.handle(locations: locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
