import { describe, expect, it } from "vitest";
import {
  TRANSECT_DISTANCES_KM,
  analyzeTransect,
  buildElevationUrl,
  destinationPoint,
  fetchSpotMeta,
  transectPoints,
} from "../src/elevation.js";

describe("analyzeTransect (referenssiluvut)", () => {
  it("avomeri: täysi fetch, täysin avoin", () => {
    expect(analyzeTransect(0, [0, 0, 0, 0, 0, 0, 0, 0, 0])).toEqual({ fetchKm: 20, exposure: 1 });
  });

  it("järvi jossa harju ~3 km päässä", () => {
    const result = analyzeTransect(78, [78, 78, 79, 80, 118, 130, 135, 140, 150]);
    expect(result.fetchKm).toBe(2);
    expect(result.exposure).toBeCloseTo(0.97, 2);
  });

  it("suojainen lahti: maasto nousee heti", () => {
    const result = analyzeTransect(78, [95, 102, 105, 110, 112, 115, 118, 120, 122]);
    expect(result.fetchKm).toBe(0);
    expect(result.exposure).toBe(0);
  });

  it("saari 1 km päässä katkaisee fetchin", () => {
    const result = analyzeTransect(0, [0, 0, 12, 0, 0, 0, 0, 0, 0]);
    expect(result.fetchKm).toBe(0.5);
    expect(result.exposure).toBeCloseTo(0.88, 2);
  });
});

describe("geometria", () => {
  it("destinationPoint pohjoiseen ja itään", () => {
    const north = destinationPoint(60, 25, 0, 1);
    expect(north.lat).toBeCloseTo(60.008993, 4);
    expect(north.lon).toBeCloseTo(25, 4);
    const east = destinationPoint(60, 25, 90, 1);
    expect(east.lat).toBeCloseTo(60, 3);
    expect(east.lon).toBeCloseTo(25.01797, 3);
  });

  it("transectPoints: spotti + 8 suuntaa × etäisyydet", () => {
    const points = transectPoints(60.1, 24.9);
    expect(points).toHaveLength(1 + 8 * TRANSECT_DISTANCES_KM.length);
    expect(buildElevationUrl(points)).toContain("api.open-meteo.com/v1/elevation");
  });
});

describe("fetchSpotMeta", () => {
  it("laskee oktantit vastauksesta", async () => {
    const count = 1 + 8 * TRANSECT_DISTANCES_KM.length;
    const fetchImpl = (async () =>
      new Response(JSON.stringify({ elevation: new Array(count).fill(0) }), { status: 200 })) as unknown as typeof fetch;
    const meta = await fetchSpotMeta(60.1, 24.9, fetchImpl);
    expect(meta.octants).toHaveLength(8);
    expect(meta.octants[0]).toEqual({ octant: 0, fetchKm: 20, exposure: 1 });
  });

  it("väärä pistemäärä on virhe", async () => {
    const fetchImpl = (async () =>
      new Response(JSON.stringify({ elevation: [1, 2, 3] }), { status: 200 })) as unknown as typeof fetch;
    await expect(fetchSpotMeta(60.1, 24.9, fetchImpl)).rejects.toThrow("odotettiin");
  });
});
