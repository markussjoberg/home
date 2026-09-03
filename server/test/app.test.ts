import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { createTestDb, type DbHandle } from "../src/db/index.js";
import { loadConfig } from "../src/config.js";

const windBody = {
  hourly: {
    time: ["2026-08-21T10:00", "2026-08-21T11:00", "2026-08-21T12:00", "2026-08-21T13:00"],
    wind_speed_10m: [9.0, 10.0, 11.0, 3.0],
    wind_gusts_10m: [12, 13, 15, 5],
    wind_direction_10m: [225, 230, 240, 250],
  },
};

interface NtfyPost {
  url: string;
  title: string | undefined;
  body: string;
}

function testFetch(ntfyLog: NtfyPost[] = []): typeof fetch {
  return (async (url: string, init?: RequestInit) => {
    if (url.includes("v1/elevation")) {
      const count = new URL(url).searchParams.get("latitude")!.split(",").length;
      return new Response(JSON.stringify({ elevation: new Array(count).fill(0) }), { status: 200 });
    }
    if (url.includes("overpass")) {
      return new Response(JSON.stringify({
        elements: [{ type: "node", lat: 60.101, lon: 24.9, tags: { natural: "beach", name: "Ranta" } }]
      }), { status: 200 });
    }
    if (url.includes("lipas")) {
      return new Response(JSON.stringify([]), { status: 200 });
    }
    if (url.includes("api.open-meteo.com")) {
      return new Response(JSON.stringify(windBody), { status: 200 });
    }
    if (url.includes("maanmittauslaitos") || url.includes("traficom")) {
      return new Response(new Uint8Array([0x89, 0x50]), { status: 200 });
    }
    if (url.includes("ntfy.example")) {
      const headers = (init?.headers ?? {}) as Record<string, string>;
      ntfyLog.push({ url, title: headers.Title, body: String(init?.body ?? "") });
      return new Response("ok", { status: 200 });
    }
    return new Response("not found", { status: 404 });
  }) as unknown as typeof fetch;
}

describe("app", () => {
  let dir: string;
  let app: ReturnType<typeof createApp>["app"];
  let checkAlerts: ReturnType<typeof createApp>["checkAlerts"];
  let ntfyLog: NtfyPost[];
  let database: DbHandle;
  const auth = { headers: { authorization: "Bearer secret" } };

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "noste-app-"));
    ntfyLog = [];
    database = await createTestDb();
    const config = loadConfig({
      NOSTE_TOKEN: "secret",
      CLIENT_TOKEN: "client",
      MML_API_KEY: "mml-key",
      NTFY_URL: "https://ntfy.example/noste",
      DATA_DIR: join(dir, "data"),
      TILE_CACHE_DIR: join(dir, "tiles"),
    } as NodeJS.ProcessEnv);
    ({ app, checkAlerts } = createApp({
      config,
      db: database.db,
      fetchImpl: testFetch(ntfyLog),
      now: () => new Date("2026-08-21T08:00:00Z"),
    }));
  });

  afterEach(async () => {
    await database.close();
    await rm(dir, { recursive: true, force: true });
  });

  it("healthz on avoin", async () => {
    const res = await app.request("/healthz");
    expect(res.status).toBe(200);
  });

  it("api vaatii tokenin, header tai query kelpaa", async () => {
    expect((await app.request("/api/spots")).status).toBe(401);
    expect((await app.request("/api/spots", auth)).status).toBe(200);
    expect((await app.request("/api/spots?token=secret")).status).toBe(200);
  });

  it("client-token kelpaa lukureiteille muttei synkkaan", async () => {
    const client = { headers: { authorization: "Bearer client" } };
    expect((await app.request("/api/forecast?lat=60.1&lon=24.9", client)).status).toBe(200);
    expect((await app.request("/api/tiles/terrain/12/2331/1186.png?token=client")).status).toBe(200);
    expect((await app.request("/api/observation?lat=60.1&lon=24.9", client)).status).not.toBe(401);
    // Yksityiset reitit (synkka, kelivahti) vaativat täyden tokenin.
    expect((await app.request("/api/spots", client)).status).toBe(401);
    expect((await app.request("/api/alerts", client)).status).toBe(401);
  });

  it("väärä token ei kelpaa mihinkään", async () => {
    const bad = { headers: { authorization: "Bearer väärä" } };
    expect((await app.request("/api/forecast?lat=60&lon=24", bad)).status).toBe(401);
    expect((await app.request("/api/spots", bad)).status).toBe(401);
  });

  it("openmeteo-läpisyöttö palauttaa lähteen rungon", async () => {
    const res = await app.request("/api/openmeteo/forecast?latitude=60&longitude=24", auth);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.hourly.wind_speed_10m).toHaveLength(4);
  });

  it("koottu ennuste vaatii koordinaatit", async () => {
    expect((await app.request("/api/forecast", auth)).status).toBe(400);
    const res = await app.request("/api/forecast?lat=60.1&lon=24.9", auth);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.wind).toHaveLength(4);
    expect(body.fetchedAt).toBe("2026-08-21T08:00:00.000Z");
  });

  it("tiiliproxy palvelee png:n ja hylkää roskan", async () => {
    const res = await app.request("/api/tiles/terrain/10/300/400.png?token=secret");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
    expect((await app.request("/api/tiles/terrain/25/1/1.png", auth)).status).toBe(400);
    expect((await app.request("/api/tiles/muu/10/1/1.png", auth)).status).toBe(404);
  });

  it("spotit: put + get kiertää", async () => {
    const spots = [{
      id: "s1", name: "Kotispotti", latitude: 60.1, longitude: 24.9,
      waterType: "sea", sports: ["wingFoil"], isFavorite: true, notes: "",
    }];
    const put = await app.request("/api/spots", {
      method: "PUT",
      headers: { ...auth.headers, "content-type": "application/json" },
      body: JSON.stringify(spots),
    });
    expect(put.status).toBe(200);
    const get = await app.request("/api/spots", auth);
    expect(await get.json()).toEqual(spots);
  });

  it("kelivahti löytää ikkunan spotin ennusteesta", async () => {
    await app.request("/api/spots", {
      method: "PUT",
      headers: { ...auth.headers, "content-type": "application/json" },
      body: JSON.stringify([{
        id: "s1", name: "Kotispotti", latitude: 60.1, longitude: 24.9,
        waterType: "lake", sports: [], isFavorite: true, notes: "",
      }]),
    });
    await app.request("/api/alerts", {
      method: "PUT",
      headers: { ...auth.headers, "content-type": "application/json" },
      body: JSON.stringify([{
        id: "a1", spotId: "s1", spotName: "Kotispotti",
        minWind: 8, directionFrom: 180, directionTo: 315, minHours: 2, enabled: true,
      }]),
    });

    const results = await checkAlerts();
    expect(results).toHaveLength(1);
    expect(results[0]!.windows[0]).toMatchObject({ start: "2026-08-21T10:00", end: "2026-08-21T12:00", hours: 3, maxSpeed: 11 });

    const viaApi = await (await app.request("/api/alerts/matches", auth)).json();
    expect(viaApi).toHaveLength(1);
  });

  it("spotmeta lasketaan ja välimuistittuu levylle", async () => {
    const first = await app.request("/api/spotmeta?lat=60.1&lon=24.9", auth);
    expect(first.status).toBe(200);
    const meta = await first.json();
    expect(meta.octants).toHaveLength(8);
    expect(meta.octants[0].fetchKm).toBe(20);
    // Toinen kutsu tulee levycachesta (fake fetch ei haittaa — sama tulos).
    const second = await app.request("/api/spotmeta?lat=60.1&lon=24.9", auth);
    expect((await second.json()).octants).toHaveLength(8);
  });

  it("rantainfo yhdistää OSM:n ja Lipaksen", async () => {
    const res = await app.request("/api/places?lat=60.1&lon=24.9", auth);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.nearest).toHaveLength(1);
    expect(body.nearest[0]).toMatchObject({ category: "Uimaranta", name: "Ranta" });
  });

  it("hälytys toimii omilla koordinaateillaan ilman spottia", async () => {
    await app.request("/api/alerts", {
      method: "PUT", ...auth,
      body: JSON.stringify([{
        id: "a1", spotId: "poistettu", spotName: "Oma paikka", latitude: 60.1, longitude: 24.9, waterType: "sea",
        minWind: 8, goodDirections: [5, 6], enabled: true,
      }]),
    });
    const results = await checkAlerts();
    expect(results).toHaveLength(1);
    expect(results[0]!.alertId).toBe("a1");
    expect(results[0]!.spotName).toBe("Oma paikka");
    expect(results[0]!.windows[0]!.hours).toBe(3);
  });

  it("spotin tuuli-ikkuna ei itsessään hälytä", async () => {
    await app.request("/api/spots", {
      method: "PUT", ...auth,
      body: JSON.stringify([{
        id: "s1", name: "Kotispotti", latitude: 60.1, longitude: 24.9,
        waterType: "lake", sports: [], isFavorite: true, notes: "", minWind: 8, alertEnabled: true,
      }]),
    });
    expect(await checkAlerts()).toHaveLength(0);
  });

  it("kelivahti ohittaa menneet tunnit", async () => {
    // Ennusteen tunnit 10–13 UTC (9, 10, 11, 3 m/s). Kello 10:30 → ikkuna alkaa
    // käynnissä olevasta tunnista; kello 12:30 → jäljellä vain 13:00 (3 m/s), ei ikkunaa.
    const alerts = JSON.stringify([{ id: "a1", spotId: "s1", spotName: "Lauttis", latitude: 60.1, longitude: 24.9,
      waterType: "sea", minWind: 8, enabled: true }]);
    const at = async (iso: string, suffix: string) => {
      const built = createApp({
        config: loadConfig({
          NOSTE_TOKEN: "secret", CLIENT_TOKEN: "client", DATA_DIR: join(dir, `data-${suffix}`), TILE_CACHE_DIR: join(dir, `tiles-${suffix}`),
        } as NodeJS.ProcessEnv),
        db: database.db,
        fetchImpl: testFetch(),
        now: () => new Date(iso),
      });
      await built.app.request("/api/alerts", { method: "PUT", ...auth, body: alerts });
      return built.checkAlerts();
    };
    const morning = await at("2026-08-21T10:30:00Z", "a");
    expect(morning).toHaveLength(1);
    expect(morning[0]!.windows[0]!.start).toBe("2026-08-21T10:00");
    expect(await at("2026-08-21T12:30:00Z", "b")).toEqual([]);
  });

  it("rikkinäinen JSON ja puutteelliset spotit → 400, ei 500", async () => {
    const broken = await app.request("/api/spots", { method: "PUT", ...auth, body: "{not json" });
    expect(broken.status).toBe(400);
    const invalid = await app.request("/api/spots", {
      method: "PUT", ...auth, body: JSON.stringify([null, { id: 1, latitude: "x" }]),
    });
    expect(invalid.status).toBe(400);
  });

  it("bbox-reitit tarkistavat alueen", async () => {
    const client = { headers: { authorization: "Bearer client" } };
    expect((await app.request("/api/windfield?bbox=26,59,24,60", client)).status).toBe(400);
    expect((await app.request("/api/wavefield?bbox=0,0,50,50", client)).status).toBe(400);
    expect((await app.request("/api/seastate?bbox=24,59,26", client)).status).toBe(400);
  });

  it("samanaikaiset yhteisölisäykset säilyvät molemmat", async () => {
    const client = { headers: { authorization: "Bearer client", "content-type": "application/json" } };
    const spot = (name: string) => JSON.stringify({
      name, latitude: 60.1, longitude: 24.9, waterType: "sea", ownerKey: `owner-${name}`,
    });
    const responses = await Promise.all([
      app.request("/api/public/spots/p1", { method: "PUT", ...client, body: spot("Eka") }),
      app.request("/api/public/spots/p2", { method: "PUT", ...client, body: spot("Toka") }),
      app.request("/api/public/spots/p3", { method: "PUT", ...client, body: spot("Kolmas") }),
    ]);
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    const list = await (await app.request("/api/public/spots", client)).json() as { spots?: unknown[] } | unknown[];
    const spots = Array.isArray(list) ? list : (list.spots ?? []);
    expect(spots).toHaveLength(3);
  });

  it("ntfy-ilmoitus lähtee kerran per ikkuna", async () => {
    await app.request("/api/spots", {
      method: "PUT",
      headers: { ...auth.headers, "content-type": "application/json" },
      body: JSON.stringify([{
        id: "s1", name: "Kotispotti", latitude: 60.1, longitude: 24.9,
        waterType: "lake", sports: [], isFavorite: true, notes: "",
      }]),
    });
    await app.request("/api/alerts", {
      method: "PUT",
      headers: { ...auth.headers, "content-type": "application/json" },
      body: JSON.stringify([{
        id: "a1", spotId: "s1", spotName: "Kotispotti",
        minWind: 8, minHours: 2, enabled: true,
      }]),
    });

    await checkAlerts();
    expect(ntfyLog).toHaveLength(1);
    expect(ntfyLog[0]!.title).toBe("Kelivahti: Kotispotti");
    expect(ntfyLog[0]!.body).toContain("max 11.0 m/s");

    // Sama ikkuna toisella kierroksella → ei uutta ilmoitusta.
    await checkAlerts();
    expect(ntfyLog).toHaveLength(1);
  });
});
