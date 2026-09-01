import SwiftUI
import MapKit
import NosteCore

/// Windy-tyylinen tuulipartikkelianimaatio kartan päällä. Tekniikka on sama
/// kuin earth.nullschool.netissä / leaflet-velocityssä (avoin algoritmi):
/// karkea tuulihila, bilineaarinen interpolointi ja partikkelien advektointi
/// häntineen. Hila tulee palvelimelta (Open-Meteo, yksi kutsu / alue).
struct WindCell: Codable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var direction: Double
}

/// Partikkelimalli: askelletaan piirron tahdissa (ei @Published — Canvas
/// lukee suoraan, SwiftUI ei diffaa joka framea).
final class WindParticleModel {
    struct Particle {
        var latitude: Double
        var longitude: Double
        var age: Int
        /// Elinikä frameina; vaihtelee jotta partikkelit eivät kuole tahdissa.
        var lifetime: Int
        var trail: [(Double, Double)] = []

        /// Häivytys syntyessä ja kuollessa (0…1) — ilman tätä viivat
        /// ilmestyisivät ja katoaisivat kesken kaiken kuin katkaistuina.
        var fade: Double {
            let fadeIn = min(1, Double(age) / 18)
            let fadeOut = min(1, Double(lifetime - age) / 30)
            return max(0, min(fadeIn, fadeOut))
        }
    }

    private(set) var particles: [Particle] = []
    private var cells: [WindCell] = []
    private var minLat = 0.0, maxLat = 0.0, minLon = 0.0, maxLon = 0.0
    private var seed: UInt64 = 0x9E3779B97F4A7C15
    private var lastStep: Date?

    var isReady: Bool { !cells.isEmpty }

    func update(cells: [WindCell], region: MKCoordinateRegion) {
        self.cells = cells
        minLat = region.center.latitude - region.span.latitudeDelta / 2
        maxLat = region.center.latitude + region.span.latitudeDelta / 2
        minLon = region.center.longitude - region.span.longitudeDelta / 2
        maxLon = region.center.longitude + region.span.longitudeDelta / 2
        // Alkutäytössä iät hajautetaan, ettei koko kenttä syty ja sammu yhtä aikaa.
        particles = (0..<220).map { _ in spawn(initialAge: Int(random01() * 120)) }
    }

    /// Aikajanan tunti vaihtuu: kenttä vaihdetaan alta, partikkelit jatkavat
    /// matkaansa uudessa kentässä (ei hyppäystä).
    func setCells(_ cells: [WindCell]) {
        self.cells = cells
    }

    /// Kevyt deterministinen satunnaisuus (Date/random ei tarpeen).
    private func random01() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 11) & 0xFFFFF) / Double(0xFFFFF)
    }

    private func spawn(initialAge: Int = 0) -> Particle {
        Particle(
            latitude: minLat + random01() * (maxLat - minLat),
            longitude: minLon + random01() * (maxLon - minLon),
            age: initialAge,
            lifetime: 120 + Int(random01() * 80)
        )
    }

    /// Tuuli pisteessä: käänteisetäisyyspainotus lähisoluista (hila on karkea).
    func wind(atLat lat: Double, lon: Double) -> (u: Double, v: Double, speed: Double)? {
        guard !cells.isEmpty else { return nil }
        var sumU = 0.0, sumV = 0.0, sumW = 0.0
        for cell in cells {
            let dLat = cell.latitude - lat
            let dLon = (cell.longitude - lon) * cos(lat * .pi / 180)
            let dist2 = dLat * dLat + dLon * dLon
            let weight = 1.0 / max(dist2, 1e-6)
            // Suunta = mistä tuulee → liike on vastakkaiseen suuntaan.
            let rad = (cell.direction + 180) * .pi / 180
            sumU += sin(rad) * cell.speed * weight
            sumV += cos(rad) * cell.speed * weight
            sumW += weight
        }
        let u = sumU / sumW
        let v = sumV / sumW
        return (u, v, (u * u + v * v).squareRoot())
    }

    func step(now: Date) {
        let dt = min(lastStep.map { now.timeIntervalSince($0) } ?? 0.016, 0.05)
        lastStep = now
        guard isReady else { return }
        // Liikeskaala suhteessa näkymän kokoon: sama fiilis joka zoomilla.
        let scale = (maxLat - minLat) * 0.0016 * dt * 60
        for i in particles.indices {
            var p = particles[i]
            guard let wind = wind(atLat: p.latitude, lon: p.longitude) else { continue }
            p.trail.append((p.latitude, p.longitude))
            if p.trail.count > 6 { p.trail.removeFirst() }
            p.latitude += wind.v * scale
            p.longitude += wind.u * scale / max(0.2, cos(p.latitude * .pi / 180))
            p.age += 1
            let outside = p.latitude < minLat || p.latitude > maxLat
                || p.longitude < minLon || p.longitude > maxLon
            particles[i] = (p.age >= p.lifetime || outside) ? spawn() : p
        }
    }
}

struct WindFieldOverlay: View {
    let model: WindParticleModel
    let region: MKCoordinateRegion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                model.step(now: timeline.date)
                let minLat = region.center.latitude - region.span.latitudeDelta / 2
                let maxLat = region.center.latitude + region.span.latitudeDelta / 2
                let minLon = region.center.longitude - region.span.longitudeDelta / 2
                let spanLat = region.span.latitudeDelta
                let spanLon = region.span.longitudeDelta

                func project(_ lat: Double, _ lon: Double) -> CGPoint {
                    CGPoint(
                        x: (lon - minLon) / spanLon * size.width,
                        y: (maxLat - lat) / spanLat * size.height
                    )
                }

                for particle in model.particles {
                    guard particle.trail.count > 1 else { continue }
                    let speed = model.wind(atLat: particle.latitude, lon: particle.longitude)?.speed ?? 0
                    var path = Path()
                    path.move(to: project(particle.trail[0].0, particle.trail[0].1))
                    for point in particle.trail.dropFirst() {
                        path.addLine(to: project(point.0, point.1))
                    }
                    path.addLine(to: project(particle.latitude, particle.longitude))
                    // Väri nopeudella: tyyni valkoinen → navakka syaani → kova kulta.
                    let color: Color = speed < 4 ? .white : (speed < 9 ? .cyan : .yellow)
                    context.stroke(path, with: .color(color.opacity(0.55 * particle.fade)), lineWidth: 1.4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
