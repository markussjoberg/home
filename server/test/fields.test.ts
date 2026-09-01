import { describe, expect, it } from "vitest";
import { FIELD_FORECAST_DAYS, GRID_SIZE, buildWindFieldUrl, parseWindField } from "../src/windfield.js";
import { MIN_WAVE_SPAN_LAT, MIN_WAVE_SPAN_LON, buildWaveFieldUrl, expandWaveBBox, parseWaveField } from "../src/wavefield.js";

const times = ["2026-09-01T00:00", "2026-09-01T01:00", "2026-09-01T02:00"];

describe("tuuli- ja aaltohilat", () => {
  it("hila kattaa alueen kulmasta kulmaan yhdellä kutsulla, tunneittain", () => {
    for (const build of [buildWindFieldUrl, buildWaveFieldUrl]) {
      const url = new URL(build(24.0, 59.8, 26.0, 60.6));
      const lats = url.searchParams.get("latitude")!.split(",");
      const lons = url.searchParams.get("longitude")!.split(",");
      expect(lats).toHaveLength(GRID_SIZE * GRID_SIZE);
      expect(lons).toHaveLength(GRID_SIZE * GRID_SIZE);
      expect(lats[0]).toBe("59.800");
      expect(lons[0]).toBe("24.000");
      expect(lats.at(-1)).toBe("60.600");
      expect(lons.at(-1)).toBe("26.000");
      expect(url.searchParams.get("timezone")).toBe("UTC");
      expect(url.searchParams.get("forecast_days")).toBe(String(FIELD_FORECAST_DAYS));
    }
    expect(buildWindFieldUrl(24, 59, 25, 60)).toContain("api.open-meteo.com/v1/forecast");
    expect(buildWindFieldUrl(24, 59, 25, 60)).toContain("wind_speed_unit=ms");
    expect(buildWindFieldUrl(24, 59, 25, 60)).toContain("hourly=wind_speed_10m%2Cwind_direction_10m");
    expect(buildWaveFieldUrl(24, 59, 25, 60)).toContain("marine-api.open-meteo.com/v1/marine");
    expect(buildWaveFieldUrl(24, 59, 25, 60)).toContain("hourly=wave_height%2Cwave_direction%2Cwave_period");
  });

  it("tuulihila: yhteinen aikataulukko, puutteelliset pisteet karsitaan", () => {
    const series = parseWindField([
      { latitude: 60, longitude: 25, hourly: { time: times, wind_speed_10m: [7.5, 8, 8.5], wind_direction_10m: [220, 225, 230] } },
      { latitude: 60.1, longitude: 25, hourly: { time: times, wind_speed_10m: [1, null, 2], wind_direction_10m: [0, 0, 0] } },
      { latitude: 60.2, longitude: 25 },
    ]);
    expect(series.times).toEqual(times);
    expect(series.cells).toEqual([{ latitude: 60, longitude: 25, speed: [7.5, 8, 8.5], direction: [220, 225, 230] }]);
    expect(parseWindField(null)).toEqual({ times: [], cells: [] });
  });

  it("aaltohila: maapisteet karsitaan, aukot täytetään, mallisolut yhdistetään", () => {
    const sea = { latitude: 60.125, longitude: 24.875, hourly: { time: times, wave_height: [0.18, null, 0.22], wave_direction: [223, 225, null], wave_period: [2.65, 2.7, 2.8] } };
    const land = { latitude: 60.625, longitude: 24.958, hourly: { time: times, wave_height: [null, null, null], wave_direction: [null, null, null], wave_period: [null, null, null] } };
    const noPeriod = { latitude: 59.79, longitude: 24.46, hourly: { time: times, wave_height: [0.32, 0.3, 0.3], wave_direction: [248, 250, 250] } };
    const { times: parsedTimes, cells } = parseWaveField([sea, sea, land, noPeriod]);
    expect(parsedTimes).toEqual(times);
    expect(cells).toEqual([
      { latitude: 60.125, longitude: 24.875, height: [0.18, 0.18, 0.22], direction: [223, 225, 225], period: [2.65, 2.7, 2.8] },
      { latitude: 59.79, longitude: 24.46, height: [0.32, 0.3, 0.3], direction: [248, 250, 250], period: [0, 0, 0] },
    ]);
    expect(parseWaveField(null)).toEqual({ times: [], cells: [] });
    expect(parseWaveField({ error: true }).cells).toEqual([]);
  });

  it("aaltoalue laajenee vähimmäiskokoon keskipisteen ympärille", () => {
    const [minLon, minLat, maxLon, maxLat] = expandWaveBBox(24.91, 60.06, 24.99, 60.14);
    expect(maxLat - minLat).toBeCloseTo(MIN_WAVE_SPAN_LAT, 6);
    expect(maxLon - minLon).toBeCloseTo(MIN_WAVE_SPAN_LON, 6);
    expect((minLat + maxLat) / 2).toBeCloseTo(60.10, 6);
    expect((minLon + maxLon) / 2).toBeCloseTo(24.95, 6);
    expect(expandWaveBBox(20, 57, 32, 68)).toEqual([20, 57, 32, 68]);
  });
});
