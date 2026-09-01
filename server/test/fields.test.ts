import { describe, expect, it } from "vitest";
import { GRID_SIZE, buildWindFieldUrl, parseWindField } from "../src/windfield.js";
import { MIN_WAVE_SPAN_LAT, MIN_WAVE_SPAN_LON, buildWaveFieldUrl, expandWaveBBox, parseWaveField } from "../src/wavefield.js";

describe("tuuli- ja aaltohilat", () => {
  it("hila kattaa alueen kulmasta kulmaan yhdellä kutsulla", () => {
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
    }
    expect(buildWindFieldUrl(24, 59, 25, 60)).toContain("api.open-meteo.com/v1/forecast");
    expect(buildWindFieldUrl(24, 59, 25, 60)).toContain("wind_speed_unit=ms");
    expect(buildWaveFieldUrl(24, 59, 25, 60)).toContain("marine-api.open-meteo.com/v1/marine");
    expect(buildWaveFieldUrl(24, 59, 25, 60)).toContain("current=wave_height%2Cwave_direction%2Cwave_period");
  });

  it("tuulihila: puutteelliset pisteet karsitaan, yksittäinen piste kelpaa", () => {
    const cells = parseWindField([
      { latitude: 60, longitude: 25, current: { wind_speed_10m: 7.5, wind_direction_10m: 220 } },
      { latitude: 60.1, longitude: 25, current: { wind_speed_10m: null } },
      { latitude: 60.2, longitude: 25 },
    ]);
    expect(cells).toEqual([{ latitude: 60, longitude: 25, speed: 7.5, direction: 220 }]);
    expect(parseWindField({ latitude: 61, longitude: 22, current: { wind_speed_10m: 3, wind_direction_10m: 90 } }))
      .toHaveLength(1);
  });

  it("aaltohila: maapisteiden null-arvot karsitaan, periodi valinnainen", () => {
    const cells = parseWaveField([
      { latitude: 60.125, longitude: 24.875, current: { wave_height: 0.18, wave_direction: 223, wave_period: 2.65 } },
      { latitude: 60.625, longitude: 24.958, current: { wave_height: null, wave_direction: null, wave_period: null } },
      { latitude: 59.79, longitude: 24.46, current: { wave_height: 0.32, wave_direction: 248, wave_period: null } },
    ]);
    expect(cells).toEqual([
      { latitude: 60.125, longitude: 24.875, height: 0.18, direction: 223, period: 2.65 },
      { latitude: 59.79, longitude: 24.46, height: 0.32, direction: 248, period: 0 },
    ]);
    // Sama mallisolu useasta pyynnöstä → yksi solu.
    const dup = { latitude: 60.125, longitude: 24.875, current: { wave_height: 0.18, wave_direction: 223, wave_period: 2.65 } };
    expect(parseWaveField([dup, dup, dup])).toHaveLength(1);
    expect(parseWaveField(null)).toEqual([]);
    expect(parseWaveField({ error: true })).toEqual([]);
  });

  it("aaltoalue laajenee vähimmäiskokoon keskipisteen ympärille", () => {
    // Pieni lahti: laajenee.
    const [minLon, minLat, maxLon, maxLat] = expandWaveBBox(24.91, 60.06, 24.99, 60.14);
    expect(maxLat - minLat).toBeCloseTo(MIN_WAVE_SPAN_LAT, 6);
    expect(maxLon - minLon).toBeCloseTo(MIN_WAVE_SPAN_LON, 6);
    expect((minLat + maxLat) / 2).toBeCloseTo(60.10, 6);
    expect((minLon + maxLon) / 2).toBeCloseTo(24.95, 6);
    // Iso näkymä: ennallaan.
    expect(expandWaveBBox(20, 57, 32, 68)).toEqual([20, 57, 32, 68]);
  });
});
