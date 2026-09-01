import { describe, expect, it } from "vitest";
import { buildWaveForecastUrl, buildWaveObservationUrl, parseWaveForecast, parseWaveObservation } from "../src/wave.js";

function element(time: string, name: string, value: number, lat = 59.96, lon = 25.23): string {
  return `<BsWfs:BsWfsElement>
    <BsWfs:Location><gml:Point><gml:pos>${lat} ${lon}</gml:pos></gml:Point></BsWfs:Location>
    <BsWfs:Time>${time}</BsWfs:Time>
    <BsWfs:ParameterName>${name}</BsWfs:ParameterName>
    <BsWfs:ParameterValue>${value}</BsWfs:ParameterValue>
  </BsWfs:BsWfsElement>`;
}

describe("fmi-aallot", () => {
  it("osoitteissa on oikeat kyselyt ja parametrit", () => {
    const obs = new URL(buildWaveObservationUrl(59.96, 25.23, () => new Date("2026-09-01T12:00:00Z")));
    expect(obs.searchParams.get("storedquery_id")).toBe("fmi::observations::wave::simple");
    expect(obs.searchParams.get("parameters")).toContain("WaveHs");
    const fc = new URL(buildWaveForecastUrl(59.96, 25.23, () => new Date("2026-09-01T12:00:00Z")));
    expect(fc.searchParams.get("storedquery_id")).toBe("fmi::forecast::wam::point::simple");
  });

  it("poijuhavainto: tuorein täysi aikaleima", () => {
    const xml = [
      element("2026-09-01T11:00:00Z", "WaveHs", 0.8),
      element("2026-09-01T11:30:00Z", "WaveHs", 1.1),
      element("2026-09-01T11:30:00Z", "ModalWDi", 210),
      element("2026-09-01T11:30:00Z", "WTP", 5.6),
      element("2026-09-01T11:30:00Z", "TWATER", 16.2),
    ].join("");
    const obs = parseWaveObservation(xml);
    expect(obs).toMatchObject({ waveHeight: 1.1, waveDirection: 210, wavePeriod: 5.6, waterTemp: 16.2 });
  });

  it("WAM-ennuste ryhmittyy tunneittain", () => {
    const xml = [
      element("2026-09-01T13:00:00Z", "SigWaveHeight", 0.9),
      element("2026-09-01T13:00:00Z", "WaveDirection", 200),
      element("2026-09-01T13:00:00Z", "WavePeriod", 5.1),
      element("2026-09-01T14:00:00Z", "SigWaveHeight", 1.2),
      element("2026-09-01T14:00:00Z", "WaveDirection", 205),
      element("2026-09-01T14:00:00Z", "WavePeriod", 5.4),
    ].join("");
    const hours = parseWaveForecast(xml);
    expect(hours).toHaveLength(2);
    expect(hours[1]).toMatchObject({ height: 1.2, direction: 205, period: 5.4 });
  });

  it("tyhjä vastaus ei kaada", () => {
    expect(parseWaveObservation("<xml/>")).toBeNull();
    expect(parseWaveForecast("<xml/>")).toHaveLength(0);
  });
});
