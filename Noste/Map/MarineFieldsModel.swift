import Foundation
import MapKit
import SwiftUI

/// Merisää-kerroksen tila ja logiikka yhdessä paikassa: hilat palvelimelta,
/// aikajana, vesimaski, rasteri, poijunudjaus ja pistehaku. Kartta ja
/// spottisivu käyttävät samaa mallia — Windyn tapaan sama kenttä ja aikajana
/// näkyvät molemmissa.
@MainActor
final class MarineFieldsModel: ObservableObject {
    let windModel = WindParticleModel()
    @Published var seaState: ServerClient.SeaState?
    @Published private(set) var windSeries: WindFieldSeries?
    @Published private(set) var waveSeries: WaveFieldSeries?
    @Published private(set) var waterMask: WaterSnapshotMask?
    @Published private(set) var waveField: WaveField?
    @Published private(set) var waveRaster: WaveFieldRaster?
    /// Aikajana: tunteja nykyhetkestä (0 = nyt). Sama valinta ohjaa tuuli- ja aaltokenttää.
    @Published var timelineOffset: Double = 0 { didSet { if timelineOffset != oldValue { timelineChanged() } } }
    /// Kerroksen tila käyttäjälle: nil = kaikki hyvin, muuten lyhyt syy.
    @Published private(set) var status: String?

    private var fetchTask: Task<Void, Never>?
    private var rasterTask: Task<Void, Never>?
    private var lastRegion: MKCoordinateRegion?

    var hasFields: Bool { windSeries != nil || waveSeries != nil }

    /// Aikajanan valittu hetki tasatunteina.
    var selectedTime: Date { FieldTime.currentHour().addingTimeInterval(timelineOffset * 3600) }

    /// Aikajanan pituus tunteina (ennusteen loppuun asti).
    var timelineHours: Double {
        let ends = [windSeries?.dates.last, waveSeries?.dates.last].compactMap { $0 }
        guard let end = ends.min() else { return 0 }
        return max(0, floor(end.timeIntervalSince(FieldTime.currentHour()) / 3600))
    }

    /// "Nyt" tai viikonpäivä + tunti Suomen ajassa.
    var timelineLabel: String {
        guard timelineOffset > 0 else { return "Nyt" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fi_FI")
        f.timeZone = TimeZone(identifier: "Europe/Helsinki")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: selectedTime)
    }

    /// Hakee poijut, tuuli- ja aaltohilat alueelle (viive perää panorointia).
    func refresh(region: MKCoordinateRegion, debounce: UInt64 = 600_000_000) {
        fetchTask?.cancel()
        lastRegion = region
        if windSeries == nil && waveSeries == nil { status = "Haetaan merisäätä…" }
        fetchTask = Task {
            if debounce > 0 { try? await Task.sleep(nanoseconds: debounce) }
            guard !Task.isCancelled else { return }
            let halfLat = region.span.latitudeDelta / 2
            let halfLon = region.span.longitudeDelta / 2
            let minLat = region.center.latitude - halfLat, maxLat = region.center.latitude + halfLat
            let minLon = region.center.longitude - halfLon, maxLon = region.center.longitude + halfLon
            async let stateTask = ServerClient.shared.seaState(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            async let fieldTask = ServerClient.shared.windField(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            async let waveTask = ServerClient.shared.waveField(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            let (state, wind, waves) = await (stateTask, fieldTask, waveTask)
            guard !Task.isCancelled else { return }
            if state == nil && wind == nil && waves == nil {
                status = (windSeries == nil && waveSeries == nil)
                    ? "Merisäätä ei saatu — tarkista verkkoyhteys."
                    : "Merisään päivitys epäonnistui, näytetään edellinen."
            } else if wind == nil && waves == nil && windSeries == nil && waveSeries == nil {
                status = "Tuuli- ja aaltokenttä ei ole saatavilla juuri nyt."
            } else {
                status = nil
            }
            if let state { seaState = state }
            if let wind, !wind.isEmpty {
                windSeries = wind
                let index = FieldTime.index(of: selectedTime, in: wind.dates) ?? 0
                windModel.update(cells: wind.cells(at: index), region: region)
            }
            if let waves, !waves.isEmpty {
                let bboxChanged = waveSeries?.bbox != waves.bbox
                waveSeries = waves
                if bboxChanged { waterMask = nil }
                applyWaveTimeline()
                if bboxChanged {
                    // Vesimaski Applen peruskartasta; aaltosolut kalibroivat vesivärin.
                    let samples = waves.cells.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let mask = await WaterSnapshotMask.build(center: waves.center, spanLat: waves.spanLat,
                                                             spanLon: waves.spanLon, waterSamples: samples)
                    guard !Task.isCancelled, waveSeries?.bbox == waves.bbox else { return }
                    waterMask = mask
                    applyWaveTimeline()
                }
            }
        }
    }

    /// Kerros pois: kaikki tyhjäksi.
    func clear() {
        fetchTask?.cancel()
        rasterTask?.cancel()
        seaState = nil
        windSeries = nil
        waveSeries = nil
        waterMask = nil
        waveField = nil
        waveRaster = nil
        status = nil
        timelineOffset = 0
    }

    private func timelineChanged() {
        if let windSeries, let index = FieldTime.index(of: selectedTime, in: windSeries.dates) {
            windModel.setCells(windSeries.cells(at: index))
        }
        applyWaveTimeline()
    }

    /// Aaltokenttä valitulle tunnille: poijukorjaus + maski → rasteri taustalla.
    private func applyWaveTimeline() {
        guard let series = waveSeries, let index = FieldTime.index(of: selectedTime, in: series.dates) else { return }
        let corrections = buoyCorrections(series: series, at: selectedTime)
        let field = series.field(at: index, mask: waterMask, corrections: corrections)
        waveField = field
        rasterTask?.cancel()
        guard field.mask != nil else { waveRaster = nil; return }
        rasterTask = Task.detached(priority: .userInitiated) { [weak self] in
            let raster = WaveFieldRaster.build(field: field)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.waveRaster = raster }
        }
    }

    /// Poijujen havainnot nudjaavat mallia: ln(havaittu/malli) poijun kohdalla
    /// havaintohetkeltä, vaimennettuna ennusteen etäisyyden mukaan (12 h e-aika).
    private func buoyCorrections(series: WaveFieldSeries, at time: Date) -> [WaveCorrection] {
        guard let buoys = seaState?.buoys else { return [] }
        let iso = ISO8601DateFormatter()
        var corrections: [WaveCorrection] = []
        for buoy in buoys {
            guard let observed = buoy.waveHeight, observed > 0.05,
                  let observedAt = iso.date(from: buoy.time),
                  let index = FieldTime.index(of: observedAt, in: series.dates) else { continue }
            let model = series.field(at: index).height(atLat: buoy.latitude, lon: buoy.longitude)
            guard model.weight > 0.2, model.height > 0.05 else { continue }
            let decay = exp(-abs(time.timeIntervalSince(observedAt)) / (12 * 3600))
            let logRatio = max(-log(2), min(log(2), log(observed / model.height))) * decay
            corrections.append(WaveCorrection(latitude: buoy.latitude, longitude: buoy.longitude, logRatio: logRatio))
        }
        return corrections
    }

    /// Tuuli pisteessä valitulle tunnille (kentän interpolointi).
    func probeWind(at coordinate: CLLocationCoordinate2D) -> ForecastProbeCard.Wind? {
        guard let wind = windModel.wind(atLat: coordinate.latitude, lon: coordinate.longitude), wind.speed > 0 else { return nil }
        let from = (atan2(wind.u, wind.v) * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
        return .init(speed: wind.speed, direction: from < 0 ? from + 360 : from)
    }

    /// Aallokko pisteessä; nil maalla tai kentän ulkopuolella.
    func probeWave(at coordinate: CLLocationCoordinate2D) -> ForecastProbeCard.Wave? {
        guard let field = waveField else { return nil }
        if let mask = field.mask, mask.isWater(lat: coordinate.latitude, lon: coordinate.longitude) == false { return nil }
        let s = field.sample(atLat: coordinate.latitude, lon: coordinate.longitude)
        guard s.weight > 0.2 else { return nil }
        let from = (atan2(s.u, s.v) * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
        return .init(height: s.height, direction: from < 0 ? from + 360 : from, period: s.period)
    }
}
