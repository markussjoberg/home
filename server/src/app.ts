import { Hono } from "hono";
import { TtlCache } from "./cache.js";
import { type Config, DEFAULT_MARINE_TEMPLATE } from "./config.js";
import { fetchSpotMeta, type SpotMeta } from "./elevation.js";
import { fetchLatestObservation, type WindObservation } from "./fmi.js";
import { type WaveBuoyObservation, type WaveForecastHour, fetchWaveData } from "./wave.js";
import { fetchLipasPlaces, fetchOsmPlaces, nearestPerCategory, type Place } from "./places.js";
import { LipasMirror, lipasNearby } from "./lipas.js";
import { LAPPIS_STORE_API, type ShopCatalog, fetchShopCatalog } from "./shop.js";
import {
  MAX_COMMENTS_PER_SPOT, MAX_PUBLIC_SPOTS, type PublicSpot, type SpotComment,
  cleanText, hashOwnerKey, parseComment, parsePublicSpot, toPublicJson,
} from "./public.js";
import { type Alert, type AlertWindow, matchAlert } from "./kelivahti.js";
import { type CombinedForecast, fetchCombinedForecast } from "./openmeteo.js";
import { JsonStore } from "./store.js";
import { TileProxy, aerialTileUrl, marineTileUrl, terrainTileUrl, validTile } from "./tiles.js";

export interface SpotSync {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  waterType: "sea" | "lake";
  sports: string[];
  isFavorite: boolean;
  notes: string;
  /** Toimivat suunnat ilmansuuntaindekseinä 0–7 (0 = N). */
  goodDirections?: number[];
  minWind?: number;
  maxWind?: number;
  /** Kelivahti päällä — palvelin johtaa hälytyksen näistä kentistä. */
  alertEnabled?: boolean;
}

/** Johtaa hälytyksen spotin tuuli-ikkunasta (sama logiikka kuin appin puolella). */
export function alertFromSpot(spot: SpotSync): Alert | null {
  if (!spot.alertEnabled) return null;
  if (spot.minWind === undefined && spot.maxWind === undefined && !spot.goodDirections?.length) {
    return null; // ei ikkunaa jota vahtia
  }
  return {
    id: `spot-${spot.id}`,
    spotId: spot.id,
    spotName: spot.name,
    minWind: spot.minWind ?? 0,
    maxWind: spot.maxWind,
    goodDirections: spot.goodDirections,
    minHours: 2,
    enabled: true,
  };
}

export interface SessionSync {
  id: string;
  startDate: string;
  sport: string;
  summary: unknown;
  track?: unknown;
  /** Tuuliarvosana 0–5 (0 = ei riittänyt). Uudelleenvienti samalla id:llä päivittää. */
  rating?: number;
  /** Session aikana vallinnut tuuli {speed, gust, direction}. */
  wind?: unknown;
  /** Kiihtyvyysraakadata (MotionLog-binääri base64:na) — kalibrointia varten. */
  motion?: string;
}

export interface AppDeps {
  config: Config;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

export function createApp({ config, fetchImpl = fetch, now = () => new Date() }: AppDeps) {
  const app = new Hono();
  const store = new JsonStore(config.dataDir);
  const tiles = new TileProxy(config.tileCacheDir, config.tileCacheTtl, fetchImpl);
  const forecastCache = new TtlCache<CombinedForecast>(config.forecastCacheTtl);
  const passthroughCache = new TtlCache<unknown>(config.forecastCacheTtl);
  const observationCache = new TtlCache<WindObservation | null>(300);

  app.get("/healthz", (c) => c.json({ ok: true }));

  // Kaikki /api-reitit vaativat tokenin (headerissa tai ?token=, tiiliosoitteita
  // varten). Kaksi tasoa: NOSTE_TOKEN = kaikki reitit; CLIENT_TOKEN (appiin
  // sisäänrakennettu) = vain lukureitit — synkka ja kelivahti pysyvät yksityisinä.
  // Mahdollinen premium-rajaus tehdään myöhemmin tähän väliin.
  const readOnlyPaths = /^\/api\/(tiles|forecast|observation|openmeteo|spotmeta|places|shop|wave)\b/;
  // Yhteisöreitit (julkiset spotit + kommentit): myös kirjoitus onnistuu appiin
  // upotetulla tokenilla — omistajuus varmistetaan laitekohtaisella avaimella.
  const communityPaths = /^\/api\/public\//;
  app.use("/api/*", async (c, next) => {
    if (!config.apiToken) {
      return c.json({ error: "NOSTE_TOKEN puuttuu palvelimen ympäristöstä" }, 503);
    }
    const header = c.req.header("authorization");
    const token = header ? header.replace(/^Bearer\s+/i, "") : c.req.query("token");
    const clientOk = readOnlyPaths.test(c.req.path) || communityPaths.test(c.req.path);
    const allowed = token === config.apiToken
      || (clientOk && !!config.clientToken && token === config.clientToken);
    if (!allowed) {
      return c.json({ error: "unauthorized" }, 401);
    }
    await next();
  });

  // --- Ennusteet ---

  // Läpisyöttö välimuistilla: appin OpenMeteoClient osoittaa tänne, muoto on
  // täsmälleen Open-Meteon oma. Parametrit kopioidaan kiinteään isäntään (ei SSRF-pintaa).
  const passthrough = (base: string) => async (c: any) => {
    const url = new URL(base);
    for (const [key, value] of Object.entries(c.req.query() as Record<string, string>)) {
      if (key !== "token") url.searchParams.set(key, value);
    }
    try {
      const body = await passthroughCache.getOrSet(url.toString(), async () => {
        const res = await fetchImpl(url.toString());
        if (!res.ok) throw new Error(`upstream ${res.status}`);
        return await res.json();
      });
      return c.json(body);
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  };

  app.get("/api/openmeteo/forecast", passthrough("https://api.open-meteo.com/v1/forecast"));
  app.get("/api/openmeteo/marine", passthrough("https://marine-api.open-meteo.com/v1/marine"));

  // Koottu ennuste (tuuli + aallokko) — kelivahti ja kellon snapshot käyttävät tätä.
  app.get("/api/forecast", async (c) => {
    const lat = Number(c.req.query("lat"));
    const lon = Number(c.req.query("lon"));
    const sea = c.req.query("sea") === "1";
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return c.json({ error: "lat ja lon vaaditaan" }, 400);
    }
    try {
      const key = `${lat.toFixed(3)},${lon.toFixed(3)},${sea}`;
      const forecast = await forecastCache.getOrSet(key, () =>
        fetchCombinedForecast(lat, lon, sea, 3, fetchImpl, now),
      );
      return c.json(forecast);
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  });

  // Toteutunut tuuli lähimmältä FMI-asemalta.
  app.get("/api/observation", async (c) => {
    const lat = Number(c.req.query("lat"));
    const lon = Number(c.req.query("lon"));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return c.json({ error: "lat ja lon vaaditaan" }, 400);
    }
    try {
      const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
      const observation = await observationCache.getOrSet(key, () =>
        fetchLatestObservation(lat, lon, fetchImpl),
      );
      return c.json({ observation });
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  });

  // FMI:n meriaallokko: poijuhavainto + WAM-pisteennuste. Poijudata päivittyy
  // ~30 min välein — sama välimuisti-ikä.
  const waveCache = new TtlCache<{ buoy: WaveBuoyObservation | null; forecast: WaveForecastHour[] }>(1800);
  app.get("/api/wave", async (c) => {
    const lat = Number(c.req.query("lat"));
    const lon = Number(c.req.query("lon"));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return c.json({ error: "lat ja lon vaaditaan" }, 400);
    }
    try {
      const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
      const wave = await waveCache.getOrSet(key, () => fetchWaveData(lat, lon, fetchImpl, now));
      return c.json(wave);
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  });

  // Maastoanalyysi: fetch + avoimuus ilmansuunnittain korkeusdatasta.
  // Maasto ei muutu → tulos talletetaan pysyvästi levylle.
  app.get("/api/spotmeta", async (c) => {
    const lat = Number(c.req.query("lat"));
    const lon = Number(c.req.query("lon"));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return c.json({ error: "lat ja lon vaaditaan" }, 400);
    }
    const key = `${lat.toFixed(4)},${lon.toFixed(4)}`;
    const cached = await store.read<Record<string, SpotMeta>>("spotmeta", {});
    if (cached[key]) return c.json(cached[key]);
    try {
      const meta = await fetchSpotMeta(lat, lon, fetchImpl);
      cached[key] = meta;
      await store.write("spotmeta", cached);
      return c.json(meta);
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  });

  // Rantainfo: Lipas vastataan omasta peilistä (koko aineisto levyllä,
  // viikkovirkistys taustalla) ja OSM-tulokset talletetaan levylle 7 vrk:ksi
  // paikkakohtaisesti — käytetyt spotit eivät kutsu Overpassia kuin harvoin.
  const placesCache = new TtlCache<{ nearest: Place[]; all: Place[] }>(24 * 3600);
  const lipasMirror = new LipasMirror(store, config.lipasBase, fetchImpl, now);
  const OSM_CACHE_MAX_AGE_MS = 7 * 24 * 3600 * 1000;
  app.get("/api/places", async (c) => {
    const lat = Number(c.req.query("lat"));
    const lon = Number(c.req.query("lon"));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return c.json({ error: "lat ja lon vaaditaan" }, 400);
    }
    // Kartan selailuun säädettävä säde (spottinäkymä käyttää oletusta).
    const radius = Math.min(6000, Math.max(300, Number(c.req.query("radius")) || 1500));
    try {
      const key = `${lat.toFixed(3)},${lon.toFixed(3)},r${radius}`;
      const cached = placesCache.get(key);
      if (cached) return c.json(cached);

      // OSM: levyltä jos tuore, muuten Overpassista (tyhjää ei talleteta).
      const osmCache = await store.read<Record<string, { fetchedAt: string; places: Place[] }>>("places-osm", {});
      const entry = osmCache[key];
      let osm = entry && now().getTime() - new Date(entry.fetchedAt).getTime() <= OSM_CACHE_MAX_AGE_MS
        ? entry.places
        : null;
      if (!osm) {
        osm = await fetchOsmPlaces(lat, lon, fetchImpl, radius);
        if (osm.length > 0) {
          osmCache[key] = { fetchedAt: now().toISOString(), places: osm };
          await store.write("places-osm", osmCache);
        }
      }

      // Lipas: peilistä; jos peiliä ei ole saatu kertaakaan, suoraan rajapinnasta.
      const mirror = await lipasMirror.current();
      const lipas = mirror
        ? lipasNearby(mirror, lat, lon, Math.max(3000, radius))
        : await fetchLipasPlaces(lat, lon, config.lipasBase, fetchImpl);

      const all = [...osm, ...lipas].sort((a, b) => a.distanceM - b.distanceM);
      const result = { nearest: nearestPerCategory(all), all };
      // Muistiin vain täysi tulos: jos OSM jäi saamatta (Overpass-häiriö),
      // seuraava kutsu yrittää sitä uudelleen — Lipas tulee peilistä ilmaiseksi.
      if (osm.length > 0) placesCache.set(key, result);
      return c.json(result);
    } catch (error) {
      return c.json({ error: String(error) }, 502);
    }
  });

  // Lappis-katalogi (GearAdvisorin ehdotuksiin): kaupan julkinen Store API,
  // välimuisti 24 h muistissa + levyllä — kauppaa ei kutsuta joka avauksella,
  // ja katko kaupassa ei riko appia (vanha katalogi kelpaa).
  const shopCache = new TtlCache<ShopCatalog>(24 * 3600);
  app.get("/api/shop/catalog", async (c) => {
    const cached = shopCache.get("catalog");
    if (cached) return c.json(cached);
    try {
      const fresh = await fetchShopCatalog(fetchImpl, LAPPIS_STORE_API, now);
      shopCache.set("catalog", fresh);
      await store.write("shop-catalog", fresh);
      return c.json(fresh);
    } catch {
      const disk = await store.read<ShopCatalog | null>("shop-catalog", null);
      if (disk) return c.json(disk);
      return c.json({ error: "katalogia ei saatu" }, 502);
    }
  });

  // --- Julkiset spotit ja kommentit ---

  app.get("/api/public/spots", async (c) => {
    const spots = await store.read<PublicSpot[]>("public-spots", []);
    const comments = await store.read<SpotComment[]>("spot-comments", []);
    const counts = new Map<string, number>();
    for (const comment of comments) {
      counts.set(comment.spotId, (counts.get(comment.spotId) ?? 0) + 1);
    }
    return c.json({ spots: spots.map((s) => toPublicJson(s, counts.get(s.id) ?? 0)) });
  });

  // Upsert: uusi id kelpaa kenelle vain; olemassa olevan saa yli vain sama
  // omistaja-avain (tai täysi token).
  app.put("/api/public/spots/:id", async (c) => {
    const id = cleanText(c.req.param("id"), 64);
    const body = await c.req.json().catch(() => null);
    const ownerKey = cleanText((body as Record<string, unknown> | null)?.ownerKey, 128);
    if (!id || !ownerKey) return c.json({ error: "id ja ownerKey vaaditaan" }, 400);
    const ownerHash = hashOwnerKey(ownerKey);
    const spot = parsePublicSpot(body, id, ownerHash, now());
    if (!spot) return c.json({ error: "kelvoton spotti" }, 400);

    const spots = await store.read<PublicSpot[]>("public-spots", []);
    const existing = spots.find((s) => s.id === id);
    const fullToken = (c.req.header("authorization") ?? "").includes(config.apiToken);
    if (existing && existing.ownerHash !== ownerHash && !fullToken) {
      return c.json({ error: "vain lisääjä voi muokata" }, 403);
    }
    if (!existing && spots.length >= MAX_PUBLIC_SPOTS) {
      return c.json({ error: "spottipooli täynnä" }, 507);
    }
    const updated = spots.filter((s) => s.id !== id);
    updated.push(spot);
    await store.write("public-spots", updated);
    return c.json({ ok: true });
  });

  app.delete("/api/public/spots/:id", async (c) => {
    const id = cleanText(c.req.param("id"), 64);
    const ownerKey = cleanText(c.req.query("ownerKey"), 128);
    const spots = await store.read<PublicSpot[]>("public-spots", []);
    const existing = spots.find((s) => s.id === id);
    if (!existing) return c.json({ ok: true });
    const fullToken = (c.req.header("authorization") ?? "").includes(config.apiToken);
    if (existing.ownerHash !== hashOwnerKey(ownerKey) && !fullToken) {
      return c.json({ error: "vain lisääjä voi poistaa" }, 403);
    }
    await store.write("public-spots", spots.filter((s) => s.id !== id));
    return c.json({ ok: true });
  });

  app.get("/api/public/spots/:id/comments", async (c) => {
    const id = cleanText(c.req.param("id"), 64);
    const comments = await store.read<SpotComment[]>("spot-comments", []);
    const forSpot = comments.filter((comment) => comment.spotId === id);
    return c.json({ comments: forSpot.slice(-200).reverse() });
  });

  app.post("/api/public/spots/:id/comments", async (c) => {
    const id = cleanText(c.req.param("id"), 64);
    const spots = await store.read<PublicSpot[]>("public-spots", []);
    if (!spots.some((s) => s.id === id)) return c.json({ error: "spottia ei ole" }, 404);
    const body = await c.req.json().catch(() => null);
    const comment = parseComment(body, id, now());
    if (!comment) return c.json({ error: "nimimerkki ja teksti vaaditaan" }, 400);
    const comments = await store.read<SpotComment[]>("spot-comments", []);
    const forSpot = comments.filter((existing) => existing.spotId === id);
    if (forSpot.length >= MAX_COMMENTS_PER_SPOT) {
      return c.json({ error: "kommentit täynnä" }, 507);
    }
    comments.push(comment);
    await store.write("spot-comments", comments);
    return c.json({ comment });
  });

  // --- Karttatiilet ---

  app.get("/api/tiles/:layer/:z/:x/:y", async (c) => {
    const layer = c.req.param("layer");
    const z = Number(c.req.param("z"));
    const x = Number(c.req.param("x"));
    const y = Number(c.req.param("y").replace(/\.png$/, ""));
    if (!validTile(z, x, y)) return c.json({ error: "virheellinen tiili" }, 400);

    let sourceUrl: string;
    if (layer === "terrain") {
      if (!config.mmlApiKey) return c.json({ error: "MML_API_KEY puuttuu" }, 503);
      sourceUrl = terrainTileUrl(z, x, y, config.mmlApiKey);
    } else if (layer === "aerial") {
      if (!config.mmlApiKey) return c.json({ error: "MML_API_KEY puuttuu" }, 503);
      sourceUrl = aerialTileUrl(z, x, y, config.mmlApiKey);
    } else if (layer === "marine") {
      sourceUrl = marineTileUrl(config.marineTileTemplate || DEFAULT_MARINE_TEMPLATE, z, x, y);
    } else {
      return c.json({ error: "tuntematon taso" }, 404);
    }

    const tile = await tiles.tile(layer, z, x, y, sourceUrl);
    if (!tile) return c.json({ error: "tiiltä ei saatu lähteestä" }, 502);
    return c.body(new Uint8Array(tile), 200, {
      "Content-Type": "image/png",
      "Cache-Control": "public, max-age=86400",
    });
  });

  // --- Synkka (spotit, sessiot) ---

  app.get("/api/spots", async (c) => c.json(await store.read<SpotSync[]>("spots", [])));

  app.put("/api/spots", async (c) => {
    const body = (await c.req.json()) as SpotSync[];
    if (!Array.isArray(body)) return c.json({ error: "odotettiin listaa" }, 400);
    await store.write("spots", body);
    return c.json({ ok: true, count: body.length });
  });

  app.get("/api/sessions", async (c) => {
    const sessions = await store.read<SessionSync[]>("sessions", []);
    // Kevyt listaus ilman raakajälkiä.
    return c.json(sessions.map(({ track, ...rest }) => rest));
  });

  app.post("/api/sessions", async (c) => {
    const body = (await c.req.json()) as SessionSync;
    if (!body?.id || !body?.startDate) return c.json({ error: "id ja startDate vaaditaan" }, 400);
    await store.upsertById("sessions", [body]);
    return c.json({ ok: true });
  });

  // --- Kelivahti ---

  app.get("/api/alerts", async (c) => c.json(await store.read<Alert[]>("alerts", [])));

  app.put("/api/alerts", async (c) => {
    const body = (await c.req.json()) as Alert[];
    if (!Array.isArray(body)) return c.json({ error: "odotettiin listaa" }, 400);
    await store.write("alerts", body);
    return c.json({ ok: true, count: body.length });
  });

  /** Ajaa kelivahdin nyt: hakee ennusteet ja palauttaa (ja tallettaa) osumat. */
  app.get("/api/alerts/matches", async (c) => {
    const result = await checkAlerts();
    return c.json(result);
  });

  async function checkAlerts(): Promise<{ alertId: string; spotName: string; windows: AlertWindow[] }[]> {
    const stored = (await store.read<Alert[]>("alerts", [])).filter((a) => a.enabled);
    const spots = await store.read<SpotSync[]>("spots", []);
    // Hälytykset johdetaan ensisijaisesti spottien tuuli-ikkunoista; erikseen
    // talletettu hälytys samalle spotille ohittaa johdetun.
    const covered = new Set(stored.map((a) => a.spotId));
    const derived = spots
      .map(alertFromSpot)
      .filter((a): a is Alert => a !== null && !covered.has(a.spotId));
    const alerts = [...stored, ...derived];
    const results: { alertId: string; spotName: string; windows: AlertWindow[] }[] = [];

    for (const alert of alerts) {
      const spot = spots.find((s) => s.id === alert.spotId);
      if (!spot) continue;
      try {
        const key = `${spot.latitude.toFixed(3)},${spot.longitude.toFixed(3)},${spot.waterType === "sea"}`;
        const forecast = await forecastCache.getOrSet(key, () =>
          fetchCombinedForecast(spot.latitude, spot.longitude, spot.waterType === "sea", 3, fetchImpl, now),
        );
        const windows = matchAlert(alert, forecast.wind);
        if (windows.length > 0) {
          results.push({ alertId: alert.id, spotName: alert.spotName || spot.name, windows });
        }
      } catch {
        // Yhden spotin hakuvirhe ei kaada kierrosta.
      }
    }

    if (results.length > 0) {
      await store.write("kelivahti-matches", { checkedAt: now().toISOString(), results });
      await notifyNewWindows(results);
    }
    return results;
  }

  /** Lähettää ntfy-ilmoituksen uusista ikkunoista. Sama ikkuna ilmoitetaan vain kerran. */
  async function notifyNewWindows(
    results: { alertId: string; spotName: string; windows: AlertWindow[] }[],
  ): Promise<number> {
    if (!config.ntfyUrl) return 0;
    const notified = await store.read<string[]>("kelivahti-notified", []);
    const seen = new Set(notified);
    let sent = 0;

    for (const result of results) {
      for (const window of result.windows) {
        const key = `${result.alertId}|${window.start}`;
        if (seen.has(key)) continue;
        try {
          const res = await fetchImpl(config.ntfyUrl, {
            method: "POST",
            headers: {
              Title: `Kelivahti: ${result.spotName}`,
              Tags: "wind_face",
              Priority: "default",
            },
            body:
              `Ennusteessa kelit ${window.start}–${window.end} UTC ` +
              `(${window.hours} h, max ${window.maxSpeed.toFixed(1)} m/s).`,
          });
          if (res.ok) {
            seen.add(key);
            sent++;
          }
        } catch {
          // Ilmoitusvirhe ei kaada kierrosta; yritetään seuraavalla.
        }
      }
    }

    if (sent > 0) {
      // Pidä lista kurissa: uusimmat 500 avainta riittävät duplikaattisuojaan.
      await store.write("kelivahti-notified", [...seen].slice(-500));
    }
    return sent;
  }

  return { app, checkAlerts };
}
