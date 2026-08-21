import Foundation
import Combine
import HealthKit
import CoreMotion
import CoreLocation
import WatchKit
import NosteCore

/// Ajaa session: HealthKit-treeni, GPS, kiihtyvyysanturi ja live-mittarit.
/// Raakadata (GPS-jälki + kiihtyvyys) kerätään talteen ja koko analyysi ajetaan
/// lopuksi NosteCorella; livenä näytetään kevyet versiot samoista mittareista.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {

    enum Phase {
        case idle
        case running
        case ended
    }

    @Published var phase: Phase = .idle
    @Published var sport: Sport = .wingFoil
    @Published var elapsed: TimeInterval = 0
    @Published var heartRate: Double = 0
    @Published var currentSpeed: Double = 0
    @Published var liveDistance: Double = 0
    @Published var livePumpCount: Int = 0
    @Published var liveFoilTime: TimeInterval = 0
    @Published var isOnFoil = false
    @Published var summary: SessionSummary?
    @Published var errorMessage: String?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    private var startDate = Date()
    private var timer: AnyCancellable?

    // Raakadata analyysiin. Kiihtyvyyspuskuria suojaa lukko, koska CoreMotion
    // toimittaa näytteet omassa jonossaan.
    private var trackPoints: [TrackPoint] = []
    private let motionLock = NSLock()
    private var motionSamples: [MotionSample] = []
    private var pumpDetector = PumpDetector()

    // Live-foilitunnistus (nopeushystereesi; lopullinen tulos lasketaan batchina).
    private var lastLocationTime: TimeInterval?
    private var lastLocation: CLLocation?

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

    func start(sport: Sport) {
        guard phase == .idle else { return }
        self.sport = sport
        summary = nil
        errorMessage = nil
        trackPoints = []
        motionLock.lock(); motionSamples = []; motionLock.unlock()
        pumpDetector = PumpDetector()
        livePumpCount = 0
        liveFoilTime = 0
        liveDistance = 0
        isOnFoil = false
        lastLocationTime = nil
        lastLocation = nil
        startDate = Date()

        startWorkoutSession()
        startLocation()
        startMotion()

        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.phase == .running else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate)
            self.motionLock.lock()
            self.livePumpCount = self.pumpDetector.strokeCount
            self.motionLock.unlock()
        }

        phase = .running
        WKInterfaceDevice.current().enableWaterLock()
    }

    func end() {
        guard phase == .running else { return }
        phase = .ended
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
            motion: sport.usesFoil || sport.countsPumps ? motion : []
        )
        summary = result

        let builder = builder
        builder?.endCollection(withEnd: Date()) { _, _ in
            builder?.finishWorkout { _, _ in }
        }
        session?.end()

        WatchConnectivityManager.shared.send(payload: WatchSync.SessionPayload(summary: result, track: trackPoints))
    }

    func reset() {
        phase = .idle
        summary = nil
        elapsed = 0
        heartRate = 0
        currentSpeed = 0
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

    // MARK: - GPS

    private func startLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
    }

    fileprivate func handle(locations: [CLLocation]) {
        for location in locations {
            let t = location.timestamp.timeIntervalSince(startDate)
            guard t >= 0 else { continue }
            let speed = location.speed
            trackPoints.append(TrackPoint(
                t: t,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                speed: speed,
                horizontalAccuracy: location.horizontalAccuracy
            ))
            currentSpeed = max(0, speed)
            if let previous = lastLocation, location.horizontalAccuracy <= 30, previous.horizontalAccuracy <= 30 {
                liveDistance += location.distance(from: previous)
            }
            lastLocation = location

            // Live-foilitila nopeushystereesillä.
            if isOnFoil {
                if speed >= 0 && speed < sport.touchdownSpeed {
                    isOnFoil = false
                } else if let last = lastLocationTime {
                    liveFoilTime += t - last
                }
            } else if speed >= sport.takeoffSpeed {
                isOnFoil = true
            }
            lastLocationTime = t
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
            self.pumpDetector.add(sample)
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
                self.heartRate = value
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
