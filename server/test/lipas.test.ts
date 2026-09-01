import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { LipasMirror, lipasNearby, mirrorIsStale, mirrorPageUrl, syncLipasMirror } from "../src/lipas.js";
import { JsonStore } from "../src/store.js";

function lipasItem(name: string, typeCode: number, lat: number, lon: number) {
  return { name, type: { typeCode }, location: { coordinates: { wgs84: { lat, lon } } } };
}

/** Feikki-Lipas: uimarantoja (3220) kaksi sivullista, muut tyypit tyhjiä. */
function fakeLipasFetch(log: string[] = []): typeof fetch {
  return (async (url: string) => {
    log.push(url);
    const u = new URL(url);
    const code = u.searchParams.get("typeCodes");
    const page = Number(u.searchParams.get("page"));
    let body: unknown[] = [];
    if (code === "3220") {
      if (page === 1) {
        body = Array.from({ length: 100 }, (_, i) => lipasItem(`Ranta ${i}`, 3220, 60 + i * 0.001, 24.9));
      } else if (page === 2) {
        body = [lipasItem("Viimeinen ranta", 3220, 61.0, 24.9)];
      }
    }
    return new Response(JSON.stringify(body), { status: 206 });
  }) as unknown as typeof fetch;
}

describe("lipas-peili", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "noste-lipas-"));
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("sivuosoite sisältää tyypin, sivun ja kentät", () => {
    const url = new URL(mirrorPageUrl("https://api.lipas.fi/v1", 3220, 2));
    expect(url.searchParams.get("typeCodes")).toBe("3220");
    expect(url.searchParams.get("page")).toBe("2");
    expect(url.searchParams.getAll("fields")).toContain("location.coordinates.wgs84");
  });

  it("synkka sivuttaa kunnes sivu jää vajaaksi", async () => {
    const log: string[] = [];
    const data = await syncLipasMirror("https://api.lipas.fi/v1", fakeLipasFetch(log));
    expect(data.places).toHaveLength(101);
    // 3220 haettiin 2 sivua; muut tyypit 1 sivu (tyhjä) kukin.
    const pages3220 = log.filter((u) => u.includes("typeCodes=3220"));
    expect(pages3220).toHaveLength(2);
  });

  it("tyhjä synkka heittää (vanha peili jää käyttöön)", async () => {
    const empty = (async () => new Response("[]", { status: 200 })) as unknown as typeof fetch;
    await expect(syncLipasMirror("https://api.lipas.fi/v1", empty)).rejects.toThrow();
  });

  it("vanhentuminen: tuore ei ole, viikkoa vanhempi on", () => {
    const now = new Date("2026-08-30T12:00:00Z");
    const fresh = { fetchedAt: "2026-08-28T12:00:00Z", places: [{ category: "Uimaranta", name: null, latitude: 60, longitude: 24 }] };
    const old = { ...fresh, fetchedAt: "2026-08-20T12:00:00Z" };
    expect(mirrorIsStale(fresh, now)).toBe(false);
    expect(mirrorIsStale(old, now)).toBe(true);
    expect(mirrorIsStale(null, now)).toBe(true);
  });

  it("lipasNearby suodattaa säteellä ja laskee etäisyydet", () => {
    const data = {
      fetchedAt: "2026-08-30T00:00:00Z",
      places: [
        { category: "Uimaranta", name: "Lähi", latitude: 60.001, longitude: 24.9 },
        { category: "Uimaranta", name: "Kaukana", latitude: 61.0, longitude: 24.9 },
      ],
    };
    const nearby = lipasNearby(data, 60.0, 24.9);
    expect(nearby).toHaveLength(1);
    expect(nearby[0]!.name).toBe("Lähi");
    expect(nearby[0]!.distanceM).toBeGreaterThan(50);
    expect(nearby[0]!.distanceM).toBeLessThan(200);
  });

  it("peili talletetaan levylle ja toista synkkaa ei tehdä tuoreena", async () => {
    const log: string[] = [];
    const store = new JsonStore(dir);
    const now = () => new Date("2026-08-30T12:00:00Z");
    const mirror = new LipasMirror(store, "https://api.lipas.fi/v1", fakeLipasFetch(log) as never, now);
    const first = await mirror.current();
    expect(first?.places).toHaveLength(101);
    const callsAfterFirst = log.length;
    const second = await mirror.current();
    expect(second?.places).toHaveLength(101);
    expect(log).toHaveLength(callsAfterFirst);
    // Uusi instanssi lukee levyltä ilman verkkoa.
    const reloaded = new LipasMirror(store, "https://api.lipas.fi/v1", fakeLipasFetch(log) as never, now);
    expect((await reloaded.current())?.places).toHaveLength(101);
    expect(log).toHaveLength(callsAfterFirst);
  });
});
