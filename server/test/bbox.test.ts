import { describe, expect, it } from "vitest";
import { parseBBox, roundBBox } from "../src/bbox.js";
import { TtlCache } from "../src/cache.js";

describe("parseBBox", () => {
  it("hyväksyy kelvollisen alueen", () => {
    expect(parseBBox("24.0,59.8,26.0,60.6")).toEqual({ bbox: [24.0, 59.8, 26.0, 60.6] });
  });

  it("hylkää puutteellisen, väärän järjestyksen, rajojen ylityksen ja liian ison", () => {
    for (const raw of [undefined, "", "24,59,26", "a,b,c,d", "26,59.8,24,60.6", "24,60.6,26,59.8",
      "24,59,26,95", "-190,59,26,60", "0,50,25,60", "20,40,30,65"]) {
      expect("error" in parseBBox(raw)).toBe(true);
    }
  });

  it("pyöristää 0,1°:een avaimeksi ja hauksi", () => {
    expect(roundBBox([24.91, 60.06, 24.99, 60.14])).toEqual([24.9, 60.1, 25.0, 60.1]);
  });
});

describe("TtlCache.getOrSet", () => {
  it("yhdistää samanaikaiset pyynnöt samalle avaimelle", async () => {
    const cache = new TtlCache<number>(60);
    let calls = 0;
    const produce = () => new Promise<number>((resolve) => { calls++; setTimeout(() => resolve(42), 10); });
    const [a, b, c] = await Promise.all([cache.getOrSet("k", produce), cache.getOrSet("k", produce), cache.getOrSet("k", produce)]);
    expect([a, b, c]).toEqual([42, 42, 42]);
    expect(calls).toBe(1);
    expect(await cache.getOrSet("k", produce)).toBe(42);
    expect(calls).toBe(1);
  });

  it("epäonnistunut tuotanto ei jää jumiin", async () => {
    const cache = new TtlCache<number>(60);
    await expect(cache.getOrSet("k", () => Promise.reject(new Error("x")))).rejects.toThrow("x");
    expect(await cache.getOrSet("k", async () => 7)).toBe(7);
  });
});
