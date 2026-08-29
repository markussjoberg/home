import Foundation
import Combine
import HealthKit
import CoreMotion
import CoreLocation
import WatchKit
import NosteCore

/// Ajaa session: HealthKit-treeni, GPS, kiihtyvyysanturi ja live-mittarit.
/// Raakadata (GPS-jälki + kiihtyvyys + syke) kerätään talteen ja koko analyysi
/// ajetaan lopuksi NosteCorella; livenä näytetään kevyet versiot samoista
/// mittareista.
///
/// Kaatumissuoja: sessio talletetaan levylle 30 s välein — appin kuollessa
/// seuraava käynnistys rakentaa yhteenvedon ja siirtää sen puhelimeen.
///
/// Autopaussi: paikallaanolo pausettaa (lähtöpaikan lähellä nopeammin), liike
/// vesillä jatkaa automaattisesti, mutta lähtöpaikalla tullut paussi ei jatku
/// itsekseen — ja lajille epäuskottava nopeus (autoilu) päättää session, ettei
/// unohtunut mittari pilaa dataa.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {

    enum Phase {
        case idle
        case running
        case paused
        case ended
    }

    @Published var phase: Phase = .idle
    @Published var sport: Sport = .wingFoil
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate: Double = 0
    @Published var currentSpeed: Double = 0
    @Published var liveDistance: Double = 0
    @Published var livePumpCount: Int = 0
    @Published var rideState = LiveRideTracker.State()
    @Published var summary: SessionSummary?
    @Published var errorMessage: String?
    /// Onko käynnissä oleva paussi automaattinen (autopaussi näyttää oman banderollin).
    @Published var isAutoPaused = false
    /// Ilmoitus automaattisesta päättämisestä tai edellisen session palautuksesta.
    @Published var notice: String?
    /// Viimeisin sijainti offline-karttaa varten.
    @Published var lastCoordinate: CLLocationCoordinate2D?
    /// Harvennettu jälki offline-kartan piirtoon (enintään ~600 pistettä).
    @Published var breadcrumb: [TrackPoint] = []

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    private var startDate = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var timer: AnyCancellable?
    private var ticksSinceAutosave = 0

    private var trackPoints: [TrackPoint] = []
    private var heartRateSamples: [HeartRateSample] = []
    private let motionLock = NSLock()
    private var motionSamples: [MotionSample] = []
    private var pumpDetector = PumpDetector()
    /// Viimeisin GPS-nopeus liikeanturisäikeelle (motionLock suojaa):
    /// pumppu lasketaan vain vauhdissa — uinnin käsivedot eivät ole pumppuja.
    private var gatedSpeed: Double = -1
    private var rideTracker = LiveRideTracker(sport: .wingFoil)
    private var autoPause = AutoPauseController(sport: .wingFoil)
    private var lastGoodLocation: CLLocation?
    /// Session lähtöpiste (ensimmäinen tarkka sijainti) — autopaussin "kotipiste".
    private var startAnchor: CLLocation?

    override init() {
        super.init()
        recoverInterruptedSessionIfAny()
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned)
        ]
        healthStore.requestAuthorization(toShare: share, read: read) { _, _ in }
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Elinkaari

    func start(sport: Sport) {
        guard phase == .idle else { return }
        self.sport = sport
        summary = nil
        errorMessage = nil
        notice = nil
        trackPoints = []
        heartRateSamples = []
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
        breadcrumb = []
        pausedTotal = 0
        pausedAt = nil
        startDate = Date()
        ticksSinceAutosave = 0

        startWorkoutSession()
        startLocation()
        startMotion()
        startTimer()

        phase = .running
        WKInterfaceDevice.current().enableWaterLock()
    }

    /// Käyttäjän oma paussi: kaikki anturit seis (akku), ei automaattista jatkoa.
    func pause() {
        guard phase == .running else { return }
        beginPause(automatic: false)
        locationManager.stopUpdatingLocation()
        autoPause.manualPause(t: sessionTime(Date()))
    }

    func resume() {
        guard phase == .paused else { return }
        autoPause.manualResume()
        endPause()
        startLocation()
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

        motionLock.lock()
        let motion = motionSamples
        motionLock.unlock()

        let result = SessionAnalyzer.summarize(
            sport: sport,
            startDate: startDate,
            points: trackPoints,
            motion: motion,
            heartRate: heartRateSamples
        )
        summary = result

        let builder = builder
        builder?.endCollection(withEnd: Date()) { _, _ in
            builder?.finishWorkout { _, _ in }
        }
        session?.end()

        WatchConnectivityManager.shared.send(payload: WatchSync.SessionPayload(summary: result, track: trackPoints))
        SessionRecovery.clear()
    }

    func reset() {
        phase = .idle
        summary = nil
        elapsed = 0
        heartRate = 0
        currentSpeed = 0
        notice = nil
    }

    // MARK: - Paussit

    private func beginPause(automatic: Bool) {
        phase = .paused
        isAutoPaused = automatic
        pausedAt = Date()
        currentSpeed = 0
        session?.pause()
        motionManager.stopDeviceMotionUpdates()
    }

    private func endPause() {
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
        }
        pausedAt = nil
        isAutoPaused = false
        session?.resume()
        startMotion()
        phase = .running
        WKInterfaceDevice.current().enableWaterLock()
    }

    private func sessionTime(_ date: Date) -> TimeInterval {
        date.timeIntervalSince(startDate)
    }

    private func handleAutoPauseEvent(_ event: AutoPauseController.Event) {
        switch event {
        case .none:
            break
        case .pause(let nearStart):
            guard phase == .running else { break }
            beginPause(automatic: true)
            // GPS jää päälle: automaattinen jatko ja ajontunnistus tarvitsevat sen.
            notice = nearStart
                ? "Autopaussi lähtöpaikalla — jatka kellosta, jos sessio jatkuu."
                : "Autopaussi — liike jatkaa automaattisesti."
            WKInterfaceDevice.current().play(.stop)
        case .resume:
            guard phase == .paused, isAutoPaused else { break }
            endPause()
            notice = nil
            WKInterfaceDevice.current().play(.start)
        case .endSession(let reason):
            guard phase == .paused || phase == .running else { break }
            notice = reason == .drivingDetected
                ? "Sessio päätettiin: liikkumisnopeus ei ollut enää lajille mahdollinen (autoilu?)."
                : "Sessio päätettiin: paussi kesti yli 20 minuuttia."
            WKInterfaceDevice.current().play(.stop)
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
                self.autosave()
            }
        }
    }

    // MARK: - Kaatumissuoja

    private func autosave() {
        motionLock.lock()
        let strokes = pumpDetector.currentStrokeTimes
        motionLock.unlock()
        SessionRecovery.save(SessionRecovery.State(
            sport: sport,
            startDate: startDate,
            points: trackPoints,
            strokeTimes: strokes,
            heartRate: heartRateSamples
        ))
    }

    private func recoverInterruptedSessionIfAny() {
        guard let state = SessionRecovery.load() else { return }
        SessionRecovery.clear()
        guard state.points.count >= 2 else { return }

        let recovered = SessionRecovery.summarize(state)
        WatchConnectivityManager.shared.send(payload: WatchSync.SessionPayload(summary: recovered, track: state.points))
        notice = "Kesken jäänyt \(state.sport.displayName)-sessio (\(Format.duration(recovered.duration))) palautettiin ja siirrettiin puhelimeen."
    }

    // MARK: - HealthKit

    private func startWorkoutSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .surfingSports
        configuration.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            builder.delegate = self
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            self.session = session
            self.builder = builder
        } catch {
            errorMessage = "Treenisessio ei käynnistynyt: \(error.localizedDescription)"
        }
    }

    fileprivate func recordHeartRate(_ bpm: Double) {
        heartRate = bpm
        guard phase == .running else { return }
        heartRateSamples.append(HeartRateSample(t: sessionTime(Date()), bpm: bpm))
    }

    // MARK: - GPS

    private func startLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
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

            lastCoordinate = location.coordinate
            if phase == .running {
                let point = TrackPoint(
                    t: t,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    speed: speed,
                    horizontalAccuracy: location.horizontalAccuracy
                )
                trackPoints.append(point)
                breadcrumb.append(point)
                if breadcrumb.count > 600 {
                    // Harvenna vanhaa päätä: joka toinen pois.
                    breadcrumb = breadcrumb.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
                }
                currentSpeed = max(0, speed)
                motionLock.lock(); gatedSpeed = speed; motionLock.unlock()
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

    // MARK: - Kiihtyvyys

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        let start = startDate
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Painovoiman suuntainen käyttäjäkiihtyvyys — ei riipu rannekkeen asennosta.
            let g = motion.gravity
            let ua = motion.userAcceleration
            let magnitude = max(1e-6, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
            let vertical = (ua.x * g.x + ua.y * g.y + ua.z * g.z) / magnitude * 9.81
            let sample = MotionSample(t: Date().timeIntervalSince(start), verticalAcceleration: vertical)
            self.motionLock.lock()
            self.motionSamples.append(sample)
            if self.gatedSpeed < 0 || self.gatedSpeed >= 1.5 {
                self.pumpDetector.add(sample)
            }
            self.motionLock.unlock()
        }
    }
}

// MARK: - Delegaatit

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.handle(locations: locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  quantityType == HKQuantityType(.heartRate),
                  let statistics = workoutBuilder.statistics(for: quantityType),
                  let value = statistics.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            else { continue }
            Task { @MainActor in
                self.recordHeartRate(value)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
