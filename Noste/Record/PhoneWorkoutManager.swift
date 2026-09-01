import Foundation
import Combine
import CoreMotion
import CoreLocation
import UIKit
import NosteCore

/// Session tallennus puhelimella — kaverit ilman kelloa (tai kännykkä liivissä)
/// saavat samat mittarit. Sama analytiikka, segmentointi ja kaatumissuoja kuin
/// kellossa; syke ja HealthKit-treeni puuttuvat (ei anturia). Tallennus ei
/// koskaan pysähdy itsestään — vain käyttäjä pysäyttää.
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
    /// Senhetkinen ympäristö (vesi/maissa/siirtymä) — vain infoa, ei pysäytä mitään.
    @Published var segmentKind: SessionSegment.Kind = .water
    /// Pakattu kiihtyvyysraakadata talletusta varten (kalibrointi).
    @Published var motionForSummary: Data?
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
    /// Viimeisin GPS-nopeus liikeanturisäikeelle (motionLock suojaa):
    /// pumppu lasketaan vain vauhdissa — uinnin käsivedot eivät ole pumppuja.
    private var gatedSpeed: Double = -1
    private var rideTracker = LiveRideTracker(sport: .wingFoil)
    private var segmentTracker = SegmentTracker(sport: .wingFoil)
    private var waterMasks = WaterMaskIndex(masks: [])
    private var lastGoodLocation: CLLocation?

    /// Kesken jäänyt sessio edellisestä käynnistyksestä (näytetään talletettavaksi).
    @Published var recoveredPayload: WatchSync.SessionPayload?

    override init() {
        super.init()
        // Recovery-tiedosto poistetaan vasta kun käyttäjä tallettaa session —
        // muuten näkymän sulkeminen hävittäisi sen lopullisesti.
        if let state = SessionRecovery.load() {
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
        segmentTracker = SegmentTracker(sport: sport)
        waterMasks = WaterMaskIndex(masks: PhoneWaterMasks.loadAll())
        segmentKind = .water
        livePumpCount = 0
        liveDistance = 0
        currentSpeed = 0
        lastGoodLocation = nil
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
        beginPause()
        locationManager.stopUpdatingLocation()
    }

    func resume() {
        guard phase == .paused else { return }
        endPause()
        locationManager.startUpdatingLocation()
    }

    func end() {
        guard phase == .running || phase == .paused else { return }
        if phase == .paused, let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        phase = .ended
        timer?.cancel()
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        UIApplication.shared.isIdleTimerDisabled = false

        motionLock.lock()
        let motion = motionSamples
        motionLock.unlock()

        let segments = segmentTracker.snapshot(at: trackPoints.last?.t ?? 0)
        summary = SessionAnalyzer.summarize(
            sport: sport, startDate: startDate, points: trackPoints, motion: motion,
            segments: segments.isEmpty ? nil : segments
        )
        trackForSummary = trackPoints
        motionForSummary = motion.isEmpty ? nil : MotionLog.pack(motion)
        SessionRecovery.clear()
    }

    func reset() {
        phase = .idle
        summary = nil
        elapsed = 0
        currentSpeed = 0
        notice = nil
    }

    // MARK: - Paussit (vain käyttäjän omat — sama malli kuin kellossa)

    private func beginPause() {
        phase = .paused
        pausedAt = Date()
        currentSpeed = 0
        motionManager.stopDeviceMotionUpdates()
    }

    private func endPause() {
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        startMotion()
        phase = .running
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
                let segments = self.segmentTracker.snapshot(at: self.trackPoints.last?.t ?? 0)
                SessionRecovery.save(SessionRecovery.State(
                    sport: self.sport,
                    startDate: self.startDate,
                    points: self.trackPoints,
                    strokeTimes: strokes,
                    segments: segments.isEmpty ? nil : segments
                ))
            }
        }
    }

    fileprivate func handle(locations: [CLLocation]) {
        // Käynnissä oleva sessio tallentaa AINA — vain käyttäjän oma paussi
        // (GPS pois) keskeyttää keruun.
        guard phase == .running else { return }
        for location in locations {
            let t = location.timestamp.timeIntervalSince(startDate)
            guard t >= 0 else { continue }
            let speed = location.speed
            let accurate = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 30

            trackPoints.append(TrackPoint(
                t: t,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                speed: speed,
                horizontalAccuracy: location.horizontalAccuracy
            ))
            currentSpeed = max(0, speed)
            motionLock.lock(); gatedSpeed = speed; motionLock.unlock()
            if accurate {
                if let previous = lastGoodLocation, max(0, speed) >= 1.0 {
                    liveDistance += location.distance(from: previous)
                }
                lastGoodLocation = location
            }
            rideState = rideTracker.add(t: t, speed: speed)

            let isWater = accurate ? waterMasks.isWater(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ) : nil
            segmentKind = segmentTracker.add(t: t, speed: max(0, speed), isWater: isWater)
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
            // Pumppu vain kun GPS-vauhti tiedetään ja riittää — tuntematon
            // nopeus EI kelpaa (uinnin käsivedot vuotivat laskuriin).
            if self.gatedSpeed >= 1.5 {
                self.pumpDetector.add(sample)
            }
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
