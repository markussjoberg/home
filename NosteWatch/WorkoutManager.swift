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
/// EI AUTOPAUSSIA EIKÄ AUTOSTOPPIA: tallennus ei koskaan pysähdy itsestään.
/// Vesilajeissa paikallaan olo (tuulen odotus, kellunta) on lajin ydintä, joten
/// laite ei saa tulkita sitä tauoksi. SegmentTracker luokittelee ajan
/// vesialuetiedon (offline-maski) perusteella vesi-/maissa-/siirtymäjaksoihin,
/// ja analyysi laskee mittarit vain vesijaksoista — autolla ajo tallentuu
/// sekin, mutta ei sotke tilastoja. Vain käyttäjä pysäyttää session.
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
    /// Senhetkinen ympäristö (vesi/maissa/siirtymä) — vain infoa, ei pysäytä mitään.
    @Published var segmentKind: SessionSegment.Kind = .water
    /// Ilmoitus edellisen session palautuksesta tms.
    @Published var notice: String?
    /// Viimeisin sijainti offline-karttaa varten.
    @Published var lastCoordinate: CLLocationCoordinate2D?
    /// Harvennettu jälki offline-kartan piirtoon (enintään ~600 pistettä).
    @Published var breadcrumb: [TrackPoint] = []

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// GPS-reitti HealthKitiin: Kuntoilu-appi näyttää kartan ja matkan.
    private var routeBuilder: HKWorkoutRouteBuilder?

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
    private var segmentTracker = SegmentTracker(sport: .wingFoil)
    // Sukellukset (Ultran syvyysanturi): duck divet, vedenalainen aika, syvyys.
    private var submersionManager: CMWaterSubmersionManager?
    private var submergedAt: Date?
    private var diveCount = 0
    private var diveTime: TimeInterval = 0
    private var maxDepth: Double?
    private var waterMasks = WaterMaskIndex(masks: [])
    private var lastGoodLocation: CLLocation?

    override init() {
        super.init()
        recoverInterruptedSessionIfAny()
        recoverHealthKitSessionIfAny()
    }

    /// Kaatumisen jälkeen HealthKit-treeni voi olla vielä auki: suljetaan se
    /// siististi, jotta Kuntoilu-appiin ei jää roikkuvaa treeniä. Oma jälki
    /// palautuu erikseen (SessionRecovery).
    private func recoverHealthKitSessionIfAny() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        healthStore.recoverActiveWorkoutSession { [weak self] recovered, _ in
            guard let recovered else { return }
            Task { @MainActor in
                guard let self, self.phase == .idle else { return }
                recovered.delegate = self
                self.session = recovered
                self.builder = recovered.associatedWorkoutBuilder()
                recovered.end()
            }
        }
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
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
        segmentTracker = SegmentTracker(sport: sport)
        waterMasks = WaterMaskIndex(masks: WatchConnectivityManager.shared.waterMasks)
        segmentKind = .water
        livePumpCount = 0
        liveDistance = 0
        currentSpeed = 0
        lastGoodLocation = nil
        breadcrumb = []
        pausedTotal = 0
        pausedAt = nil
        startDate = Date()
        ticksSinceAutosave = 0

        diveCount = 0
        diveTime = 0
        maxDepth = nil
        submergedAt = nil
        startSubmersion()

        startWorkoutSession()
        startLocation()
        startMotion()
        startTimer()

        phase = .running
        WKInterfaceDevice.current().enableWaterLock()
    }

    /// Käyttäjän oma paussi: kaikki anturit seis (akku). Ainoa taukotapa —
    /// laite ei koskaan pauseta itse.
    func pause() {
        guard phase == .running else { return }
        beginPause()
        locationManager.stopUpdatingLocation()
    }

    func resume() {
        guard phase == .paused else { return }
        endPause()
        startLocation()
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

        motionLock.lock()
        let motion = motionSamples
        motionLock.unlock()

        let segments = segmentTracker.snapshot(at: trackPoints.last?.t ?? 0)
        var result = SessionAnalyzer.summarize(
            sport: sport,
            startDate: startDate,
            points: trackPoints,
            motion: motion,
            heartRate: heartRateSamples,
            segments: segments.isEmpty ? nil : segments
        )
        if let since = submergedAt {
            diveTime += Date().timeIntervalSince(since)
            submergedAt = nil
        }
        submersionManager = nil
        if diveCount > 0 {
            result.dives = DiveAnalysis(count: diveCount, totalTime: diveTime, maxDepth: maxDepth)
        }
        summary = result

        // Applen järjestys: session.end() → delegaatti (.ended) → endCollection →
        // finishWorkout → reitti. Ks. finishHealthKitWorkout.
        session?.end()

        WatchConnectivityManager.shared.send(payload: WatchSync.SessionPayload(summary: result, track: trackPoints))
        // Raakakiihtyvyys talteen puhelimeen — pumppu-/foilitunnistuksen voi
        // kalibroida uudelleen jälkikäteen todellisella datalla.
        WatchConnectivityManager.shared.send(motion: motion, for: startDate)
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

    // MARK: - Paussit (vain käyttäjän omat)

    private func beginPause() {
        phase = .paused
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
        session?.resume()
        startMotion()
        phase = .running
        WKInterfaceDevice.current().enableWaterLock()
    }

    private func sessionTime(_ date: Date) -> TimeInterval {
        date.timeIntervalSince(startDate)
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

    // MARK: - Sukellukset

    private func startSubmersion() {
        guard CMWaterSubmersionManager.waterSubmersionAvailable else { return }
        let manager = CMWaterSubmersionManager()
        manager.delegate = self
        submersionManager = manager
    }

    fileprivate func handleSubmersion(_ event: CMWaterSubmersionEvent) {
        switch event.state {
        case .submerged:
            if submergedAt == nil {
                submergedAt = Date()
                diveCount += 1
            }
        case .notSubmerged, .unknown:
            if let since = submergedAt {
                diveTime += Date().timeIntervalSince(since)
                submergedAt = nil
            }
        @unknown default:
            break
        }
    }

    fileprivate func recordDepth(_ meters: Double) {
        if maxDepth == nil || meters > maxDepth! {
            maxDepth = meters
        }
    }

    // MARK: - Kaatumissuoja

    private func autosave() {
        motionLock.lock()
        let strokes = pumpDetector.currentStrokeTimes
        motionLock.unlock()
        let segments = segmentTracker.snapshot(at: trackPoints.last?.t ?? 0)
        SessionRecovery.save(SessionRecovery.State(
            sport: sport,
            startDate: startDate,
            points: trackPoints,
            strokeTimes: strokes,
            heartRate: heartRateSamples,
            segments: segments.isEmpty ? nil : segments
        ))
    }

    private func recoverInterruptedSessionIfAny() {
        guard let state = SessionRecovery.load() else { return }
        guard state.points.count >= 2 else {
            SessionRecovery.clear() // ei mitään palautettavaa
            return
        }

        // Recovery-tiedosto poistetaan vasta kun siirto puhelimeen on varmistunut —
        // WCSession ei ole vielä aktivoitunut tässä vaiheessa, ja epäonnistunut
        // lähetys hävittäisi muuten juuri sen session, jota suoja on varten.
        let recovered = SessionRecovery.summarize(state)
        summary = recovered
        WatchConnectivityManager.shared.send(payload: WatchSync.SessionPayload(summary: recovered, track: state.points)) {
            SessionRecovery.clear()
        }
        notice = "Kesken jäänyt \(state.sport.displayName)-sessio (\(Format.duration(recovered.duration))) palautettiin ja siirretään puhelimeen."
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
            session.delegate = self
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            self.session = session
            self.builder = builder
            self.routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
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
        // Käynnissä oleva sessio tallentaa AINA — mikään automatiikka ei
        // pysäytä eikä suodata keruuta. Vain käyttäjän oma paussi (GPS pois)
        // keskeyttää.
        guard phase == .running else { return }
        for location in locations {
            let t = location.timestamp.timeIntervalSince(startDate)
            guard t >= 0 else { continue }
            let speed = location.speed
            let accurate = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 30

            lastCoordinate = location.coordinate
            let point = TrackPoint(
                t: t,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                speed: speed,
                horizontalAccuracy: location.horizontalAccuracy
            )
            trackPoints.append(point)
            if accurate {
                routeBuilder?.insertRouteData([location]) { _, _ in }
            }
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

            // Segmentointi: vesialuemaski vastaa "olenko vesillä" (epätarkka
            // GPS tai maskin puute = ei tietoa = vettä). Ei koskaan pysäytä.
            let isWater = accurate ? waterMasks.isWater(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ) : nil
            segmentKind = segmentTracker.add(t: t, speed: max(0, speed), isWater: isWater)
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
            // Pumppu vain kun GPS-vauhti tiedetään ja riittää — tuntematon
            // nopeus EI kelpaa (uinnin käsivedot vuotivat laskuriin).
            if self.gatedSpeed >= 1.5 {
                self.pumpDetector.add(sample)
            }
            self.motionLock.unlock()
        }
    }
}

// MARK: - Delegaatit

extension WorkoutManager: CMWaterSubmersionManagerDelegate {
    nonisolated func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        Task { @MainActor in
            self.handleSubmersion(event)
        }
    }

    nonisolated func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {
        guard let depth = measurement.depth else { return }
        let meters = depth.converted(to: .meters).value
        Task { @MainActor in
            self.recordDepth(meters)
        }
    }

    nonisolated func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterTemperature) {}

    nonisolated func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {}
}

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.handle(locations: locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        Task { @MainActor in
            self.finishHealthKitWorkout(endDate: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}

    /// Sulkee keruun, luo HKWorkoutin ja liittää GPS-reitin siihen.
    fileprivate func finishHealthKitWorkout(endDate: Date) {
        let builder = builder
        let routeBuilder = routeBuilder
        self.builder = nil
        self.routeBuilder = nil
        self.session = nil
        builder?.endCollection(withEnd: endDate) { _, _ in
            builder?.finishWorkout { workout, _ in
                guard let workout, let routeBuilder else { return }
                routeBuilder.finishRoute(with: workout, metadata: nil) { _, _ in }
            }
        }
    }
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
