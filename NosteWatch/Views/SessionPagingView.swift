import SwiftUI
import WatchKit
import NosteCore

struct SessionPagingView: View {
    /// Sama foilin oranssi kuin puhelimessa (Theme.ride).
    static let ride = Color(red: 1.0, green: 0.62, blue: 0.25)
    @State private var selection: Tab = .metrics

    enum Tab {
        case controls
        case metrics
        case map
    }

    var body: some View {
        TabView(selection: $selection) {
            ControlsView().tag(Tab.controls)
            MetricsView().tag(Tab.metrics)
            OfflineMapView().tag(Tab.map)
        }
        .tabViewStyle(.page)
        .navigationBarBackButtonHidden(true)
    }
}

struct ControlsView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        VStack(spacing: 10) {
            Button {
                workout.end()
            } label: {
                Label("Lopeta", systemImage: "stop.fill")
            }
            .tint(.red)

            if workout.phase == .paused {
                Button {
                    workout.resume()
                } label: {
                    Label("Jatka", systemImage: "play.fill")
                }
                .tint(.green)
            } else {
                Button {
                    workout.pause()
                } label: {
                    Label("Tauko", systemImage: "pause.fill")
                }
                .tint(.orange)
            }

            Button {
                WKInterfaceDevice.current().enableWaterLock()
            } label: {
                Label("Vesilukko", systemImage: "drop.fill")
            }
            .tint(.blue)
        }
        .padding(.horizontal)
    }
}

/// Lajikohtainen mittarinäkymä: tärkein luku isoimpana.
/// Pumppaajalle se on käynnissä olevan lennon kesto, wingaajalle nopeus.
struct MetricsView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Format.duration(workout.elapsed))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if workout.phase == .paused {
                    Text("TAUKO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.black)
                } else if workout.segmentKind != .water {
                    // Info, ei tauko: tallennus jatkuu, tilastot vain vesiltä.
                    Text(workout.segmentKind == .land ? "MAISSA" : "SIIRTYMÄ")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.gray.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "heart.fill").foregroundStyle(.red).font(.caption)
                    Text(workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "–")
                        .font(.system(.body, design: .rounded))
                }
            }

            hero

            Divider().padding(.vertical, 1)

            switch workout.sport {
            case .pumpFoil:
                row("Pumput", "\(workout.livePumpCount)", .cyan)
                row("Lennot", "\(workout.rideState.rideCount)", Self.ride)
                row("Foiliaika", Format.duration(workout.rideState.totalRideTime), Self.ride)
            case .wingFoil, .parawing, .kite, .proneFoil, .dwSup:
                row("Foiliaika", Format.duration(workout.rideState.totalRideTime), Self.ride)
                row("Lennot", "\(workout.rideState.rideCount)", Self.ride)
                row("Matka", Format.distance(workout.liveDistance), .primary)
            case .surf, .sup:
                row(workout.sport == .surf ? "Aallot" : "Vedot", "\(workout.rideState.rideCount)", .cyan)
                row("Matka", Format.distance(workout.liveDistance), .primary)
                row("Nopeus", Format.speedKmh(workout.currentSpeed), .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    /// Isoin mittari: lajin tärkein, hetkessä luettava luku.
    @ViewBuilder
    private var hero: some View {
        switch workout.sport {
        case .pumpFoil:
            if workout.rideState.isRiding {
                heroText(Format.duration(workout.rideState.currentRideDuration), label: "LENNOSSA", color: Self.ride)
            } else {
                heroText("\(workout.livePumpCount)", label: "pumppua", color: .cyan)
            }
        case .wingFoil, .parawing, .kite, .proneFoil, .dwSup:
            heroText(
                Format.speedKmh(workout.currentSpeed),
                label: workout.rideState.isRiding ? "FOILILLA · \(Format.duration(workout.rideState.currentRideDuration))" : "nopeus",
                color: workout.rideState.isRiding ? Self.ride : .primary
            )
        case .surf, .sup:
            heroText(
                Format.speedKmh(workout.currentSpeed),
                label: workout.rideState.isRiding ? "AALLOSSA · \(Format.duration(workout.rideState.currentRideDuration))" : "nopeus",
                color: workout.rideState.isRiding ? Self.ride : .primary
            )
        }
    }

    private func heroText(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(color == .primary ? .secondary : color)
        }
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(color)
        }
    }
}
