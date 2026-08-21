import SwiftUI
import WatchKit
import NosteCore

struct SessionPagingView: View {
    @State private var selection: Tab = .metrics

    enum Tab {
        case controls
        case metrics
    }

    var body: some View {
        TabView(selection: $selection) {
            ControlsView().tag(Tab.controls)
            MetricsView().tag(Tab.metrics)
        }
        .tabViewStyle(.page)
        .navigationBarBackButtonHidden(true)
    }
}

struct ControlsView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        VStack(spacing: 12) {
            Button {
                workout.end()
            } label: {
                Label("Lopeta", systemImage: "stop.fill")
            }
            .tint(.red)

            Button {
                WKInterfaceDevice.current().enableWaterLock()
            } label: {
                Label("Vesilukko", systemImage: "drop.fill")
            }
            .tint(.blue)
        }
        .padding()
    }
}

struct MetricsView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.duration(workout.elapsed))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.yellow)

            metricRow(value: Format.speedKmh(workout.currentSpeed), label: workout.isOnFoil ? "foililla" : "nopeus",
                      color: workout.isOnFoil ? .green : .primary)

            if workout.sport.usesFoil {
                metricRow(value: Format.duration(workout.liveFoilTime), label: "foiliaika", color: .green)
            }
            if workout.sport.countsPumps {
                metricRow(value: "\(workout.livePumpCount)", label: "pumput", color: .cyan)
            }
            metricRow(value: Format.distance(workout.liveDistance), label: "matka", color: .primary)

            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text(workout.heartRate > 0 ? "\(Int(workout.heartRate))" : "–")
                    .font(.system(.title3, design: .rounded))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func metricRow(value: String, label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundStyle(color)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
