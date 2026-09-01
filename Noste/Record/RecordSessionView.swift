import SwiftUI
import SwiftData
import NosteCore

/// Session tallennus puhelimella: lajivalinta → mittarinäkymä → yhteenveto ja talletus.
struct RecordSessionView: View {
    @StateObject private var workout = PhoneWorkoutManager()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var rating: WindRating?
    @Query(sort: \GearRecord.createdAt) private var gear: [GearRecord]
    @State private var selectedGear: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                switch workout.phase {
                case .idle:
                    sportPicker
                case .running, .paused:
                    metrics
                case .ended:
                    ended
                }
            }
            .navigationTitle("Tallenna puhelimella")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if workout.phase == .idle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Sulje") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(workout.phase == .running || workout.phase == .paused)
        }
    }

    private var sportPicker: some View {
        List {
            if let recovered = workout.recoveredPayload {
                Section {
                    Button {
                        store(payload: recovered)
                        workout.recoveredPayload = nil
                    } label: {
                        Label("Talleta kesken jäänyt \(recovered.summary.sport.displayName)-sessio (\(Format.duration(recovered.summary.duration)))",
                              systemImage: "arrow.counterclockwise.circle.fill")
                    }
                } header: {
                    Text("Palautettu sessio")
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Sport.allCases) { sport in
                        Button {
                            workout.start(sport: sport)
                        } label: {
                            VStack(spacing: 10) {
                                SportIcon(sport: sport, size: 44)
                                    .foregroundStyle(.tint)
                                Text(sport.displayName)
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Aloita sessio")
            } footer: {
                Text("Puhelin mittaa GPS:llä ja liikeanturilla — pidä se mukana (liivi/vyötärötaskussa pumpputunnistus toimii parhaiten). Sykettä ei mitata ilman kelloa. Tallennus ei pysähdy itsestään: maissa ja siirtymissä kerätty aika merkitään erikseen, eikä se sotke tilastoja.")
            }
        }
    }

    private var metrics: some View {
        VStack(spacing: 16) {
            HStack {
                Text(Format.duration(workout.elapsed))
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                if workout.phase == .paused {
                    Text("TAUKO")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.black)
                } else if workout.segmentKind != .water {
                    // Info, ei tauko: tallennus jatkuu, tilastot vain vesiltä.
                    Text(workout.segmentKind == .land ? "MAISSA" : "SIIRTYMÄ")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.gray.opacity(0.4), in: Capsule())
                        .foregroundStyle(.primary)
                }
            }

            if let notice = workout.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Grid(horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    metric(Format.speedKmh(workout.currentSpeed),
                           workout.rideState.isRiding ? "foililla" : "nopeus",
                           workout.rideState.isRiding ? .green : .primary)
                    metric(Format.distance(workout.liveDistance), "matka", .primary)
                }
                GridRow {
                    if workout.sport.usesFoil {
                        metric(Format.duration(workout.rideState.totalRideTime), "foiliaika", .green)
                        metric("\(workout.rideState.rideCount)", "lennot", .green)
                    } else {
                        metric("\(workout.rideState.rideCount)",
                               workout.sport == .surf ? "aallot" : "vedot", .cyan)
                        metric(Format.duration(workout.rideState.currentRideDuration), "meneillään", .green)
                    }
                }
                if workout.sport.countsPumps {
                    GridRow {
                        metric("\(workout.livePumpCount)", "pumput", .cyan)
                        metric(Format.duration(workout.rideState.currentRideDuration), "lento nyt", .green)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    workout.phase == .paused ? workout.resume() : workout.pause()
                } label: {
                    Label(workout.phase == .paused ? "Jatka" : "Tauko",
                          systemImage: workout.phase == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(workout.phase == .paused ? .green : .orange)

                Button {
                    workout.end()
                } label: {
                    Label("Lopeta", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var ended: some View {
        List {
            if let notice = workout.notice {
                Section {
                    Label(notice, systemImage: "info.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            if let summary = workout.summary {
                Section("Yhteenveto") {
                    LabeledContent("Kesto", value: Format.duration(summary.duration))
                    LabeledContent("Matka", value: Format.distance(summary.distance))
                    LabeledContent("Maksiminopeus", value: Format.speedKmh(summary.maxSpeed))
                    if summary.sport.usesFoil {
                        LabeledContent("Foiliaika", value: "\(Format.duration(summary.rides.totalDuration)) (\(Format.percent(summary.rideFraction)))")
                        LabeledContent("Lennot", value: "\(summary.rides.count)")
                    }
                    if let pumps = summary.pumps {
                        LabeledContent("Pumput", value: "\(pumps.strokeCount)")
                    }
                }
                if !summary.sport.countsPumps {
                    Section("Millainen tuuli?") {
                        RatingControl(rating: rating) { rating = $0 }
                    }
                }
                if !gear.isEmpty {
                    Section("Millä kalustolla?") {
                        ForEach(gear) { item in
                            Button {
                                if !selectedGear.insert(item.id).inserted {
                                    selectedGear.remove(item.id)
                                }
                            } label: {
                                HStack {
                                    Label { Text(item.displayName).foregroundStyle(.primary) } icon: {
                                        GearIcon(type: item.type, size: 24).foregroundStyle(.tint)
                                    }
                                    Spacer()
                                    if selectedGear.contains(item.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        store(payload: WatchSync.SessionPayload(summary: summary, track: workout.trackForSummary))
                        dismiss()
                    } label: {
                        Label("Tallenna sessio", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Hylkää", role: .destructive) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func metric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 130)
    }

    private func store(payload: WatchSync.SessionPayload) {
        let record = SessionRecord(summary: payload.summary, track: payload.track)
        record.gearIDs = selectedGear.isEmpty ? nil : Array(selectedGear)
        record.motionData = workout.motionForSummary
        modelContext.insert(record)
        try? modelContext.save()
        let context = modelContext
        let chosenRating = rating
        let motion = record.motionData
        Task {
            if let chosenRating {
                await RatingService.apply(rating: chosenRating, to: record, context: context)
            } else {
                await ServerClient.shared.backupSession(payload, id: record.id, motion: motion)
            }
        }
    }
}
