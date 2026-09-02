import { Hono } from "hono";
import { TtlCache } from "./cache.js";
import { type Config, DEFAULT_MARINE_TEMPLATE } from "./config.js";
import { fetchSpotMeta, type SpotMeta } from "./elevation.js";
import { fetchLatestObservation, type WindObservation } from "./fmi.js";
import { type SeaStateStation, type WaveBuoyObservation, type WaveForecastHour, fetchSeaState, fetchWaveData } from "./wave.js";
import { type WindFieldSeries, fetchWindField } from "./windfield.js";
import { parseBBox, roundBBox } from "./bbox.js";
import type { Db } from "./db/index.js";
import {
  addComment, countComments, countSpots, deleteSpot, getSpot, listComments, listRevisions, listSpots,
  migrateCommunityJson, saveSpot,
} from "./community.js";
import { type WaveFieldSeries, expandWaveBBox, fetchWaveField } from "./wavefield.js";
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
  /** Vanha lippu; hälytykset ovat nykyään omia tietueita (/api/alerts). */
  alertEnabled?: boolean;
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
  /** Tietokanta (Postgres tai PGlite) — yhteisödata. */
  db: Db;
}

export function createApp({ config, fetchImpl = fetch, now = () => new Date(), db }: AppDeps) {
  const app = new Hono();
  const store = new JsonStore(config.dataDir);
  const tiles = new TileProxy(config.tileCacheDir, config.tileCacheTtl, fetchImpl);
  const forecastCache = new TtlCache<CombinedForecast>(config.forecastCacheTtl);
  const passthroughCache = new TtlCache<unknown>(config.forecastCacheTtl);
  const observationCache = new TtlCache<WindObservation | null>(300);

  app.get("/healthz", (c) => c.json({ ok: true }));

  // Odottamaton virhe: JSON-vastaus ja lokimerkintä Honon text/plain-500:n sijaan.
  app.onError((error, c) => {
    console.error(`${c.req.method} ${c.req.path}:`, error);
    return c.json({ error: "palvelinvirhe" }, 500);
  });

  /** Rungon JSON tai null (kutsuja vastaa 400) — rikkinäinen JSON ei saa olla 500. */
  const readJson = async <T,>(c: { req: { json(): Promise<unknown> } }): Promise<T | null> =>
    (await c.req.json().catch(() => null)) as T | null;

  // Kaikki /api-reitit vaativat tokenin (headerissa tai ?token=, tiiliosoitteita
  // varten). Kaksi tasoa: NOSTE_TOKEN = kaikki reitit; CLIENT_TOKEN (appiin
  // sisäänrakennettu) = vain lukureitit — synkka ja kelivahti pysyvät yksityisinä.
  // Mahdollinen premium-rajaus tehdään myöhemmin tähän väliin.
  const readOnlyPaths = /^\/api\/(tiles|forecast|observation|openmeteo|spotmeta|places|shop|wave|seastate|windfield|wavefield)\b/;
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

  // Merisää kartalle: kaikki aaltopoijut + tuuliasemat näkyvällä alueella.
  const seaStateCache = new TtlCache<{ buoys: SeaStateStation[]; stations: SeaStateStation[] }>(900);
  app.get("/api/seastate", async (c) => {
    const parsed = parseBBox(c.req.query("bbox"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    const bbox = roundBBox(parsed.bbox).map((v) => v.toFixed(1)).join(",");
    try {
      const state = await seaStateCache.getOrSet(bbox, () => fetchSeaState(bbox, fetchImpl, now));
      return c.json(state);
    } catch (error) {
      console.error("seastate: FMI-haku epäonnistui", bbox, String(error));
      return c.json({ error: String(error) }, 502);
    }
  });

  // Tuulikenttä partikkelianimaatioon: 9×9-hila Open-Meteosta kaikille
  // ennustetunneille (aikajana appissa), 30 min välimuisti. Haetaan
  // pyöristetyllä alueella, jotta avain ja hila vastaavat toisiaan.
  const windFieldCache = new TtlCache<WindFieldSeries>(1800);
  app.get("/api/windfield", async (c) => {
    const parsed = parseBBox(c.req.query("bbox"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    const bbox = roundBBox(parsed.bbox);
    const key = bbox.map((v) => v.toFixed(1)).join(",");
    try {
      const series = await windFieldCache.getOrSet(key, () => fetchWindField(...bbox, fetchImpl));
      return c.json(series);
    } catch (error) {
      console.error("windfield: Open-Meteo-haku epäonnistui", key, String(error));
      return c.json({ error: String(error) }, 502);
    }
  });

  // Aaltokenttä (korkeus, suunta, periodi) samalla reseptillä Open-Meteon
  // marine-mallista; maapisteet karsittu jo palvelimella.
  const waveFieldCache = new TtlCache<WaveFieldSeries>(1800);
  app.get("/api/wavefield", async (c) => {
    const parsed = parseBBox(c.req.query("bbox"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    const bbox = parsed.bbox;
    // Avain laajennetusta alueesta: lähekkäiset pienet näkymät jakavat tuloksen.
    const key = expandWaveBBox(...bbox).map((v) => v.toFixed(1)).join(",");
    try {
      const result = await waveFieldCache.getOrSet(key, () => fetchWaveField(...bbox, fetchImpl));
      return c.json(result);
    } catch (error) {
      console.error("wavefield: Open-Meteo-haku epäonnistui", key, String(error));
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

  // Yhteisödata kannassa; vanhat JSON-tiedostot siirretään kertaalleen.
  const communityReady = migrateCommunityJson(db, store).catch((error) => {
    console.error("yhteisödatan siirto epäonnistui:", error);
  });

  app.get("/api/public/spots", async (c) => {
    await communityReady;
    const rows = await listSpots(db);
    return c.json({ spots: rows.map((r) => toPublicJson(r.spot, r.commentCount)) });
  });

  // Upsert: uusi id kelpaa kenelle vain; olemassa olevan saa yli vain sama
  // omistaja-avain (tai täysi token). Jokainen tallennus jättää version.
  app.put("/api/public/spots/:id", async (c) => {
    await communityReady;
    const id = cleanText(c.req.param("id"), 64);
    const body = await c.req.json().catch(() => null);
    const ownerKey = cleanText((body as Record<string, unknown> | null)?.ownerKey, 128);
    if (!id || !ownerKey) return c.json({ error: "id ja ownerKey vaaditaan" }, 400);
    const ownerHash = hashOwnerKey(ownerKey);
    const fullToken = (c.req.header("authorization") ?? "").includes(config.apiToken);
    const existing = await getSpot(db, id);
    if (existing && existing.ownerHash !== ownerHash && !fullToken) {
      return c.json({ error: "vain lisääjä voi muokata" }, 403);
    }
    if (!existing && (await countSpots(db)) >= MAX_PUBLIC_SPOTS) {
      return c.json({ error: "spottipooli täynnä" }, 507);
    }
    // Omistaja säilyy alkuperäisenä myös admin-muokkauksessa.
    const spot = parsePublicSpot(body, id, existing?.ownerHash ?? ownerHash, now());
    if (!spot) return c.json({ error: "kelvoton spotti" }, 400);
    await saveSpot(db, spot, ownerHash);
    return c.json({ ok: true });
  });

  app.delete("/api/public/spots/:id", async (c) => {
    await communityReady;
    const id = cleanText(c.req.param("id"), 64);
    const ownerKey = cleanText(c.req.query("ownerKey"), 128);
    const existing = await getSpot(db, id);
    if (!existing) return c.json({ ok: true });
    const fullToken = (c.req.header("authorization") ?? "").includes(config.apiToken);
    if (existing.ownerHash !== hashOwnerKey(ownerKey) && !fullToken) {
      return c.json({ error: "vain lisääjä voi poistaa" }, 403);
    }
    await deleteSpot(db, id, now());
    return c.json({ ok: true });
  });

  /** Muokkaushistoria (ilman hasheja): wikimäinen läpinäkyvyys. */
  app.get("/api/public/spots/:id/history", async (c) => {
    await communityReady;
    const id = cleanText(c.req.param("id"), 64);
    const revisions = await listRevisions(db, id);
    return c.json({
      revisions: revisions.map((r) => ({ id: r.id, createdAt: r.createdAt.toISOString(), data: r.data })),
    });
  });

  app.get("/api/public/spots/:id/comments", async (c) => {
    await communityReady;
    const id = cleanText(c.req.param("id"), 64);
    return c.json({ comments: await listComments(db, id) });
  });

  app.post("/api/public/spots/:id/comments", async (c) => {
    await communityReady;
    const id = cleanText(c.req.param("id"), 64);
    if (!(await getSpot(db, id))) return c.json({ error: "spottia ei ole" }, 404);
    const body = await c.req.json().catch(() => null);
    const comment = parseComment(body, id, now());
    if (!comment) return c.json({ error: "nimimerkki ja teksti vaaditaan" }, 400);
    if ((await countComments(db, id)) >= MAX_COMMENTS_PER_SPOT) {
      return c.json({ error: "kommentit täynnä" }, 507);
    }
    await addComment(db, comment);
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
    const body = await readJson<SpotSync[]>(c);
    if (!Array.isArray(body)) return c.json({ error: "odotettiin listaa" }, 400);
    // Kevyt alkiotarkistus: rikkinäinen alkio kaataisi kelivahdin joka kierroksella.
    const valid = body.every(
      (spot) => spot && typeof spot === "object" && typeof spot.id === "string"
        && Number.isFinite(spot.latitude) && Number.isFinite(spot.longitude),
    );
    if (!valid) return c.json({ error: "jokaisella spotilla pitää olla id, latitude ja longitude" }, 400);
    await store.write("spots", body);
    return c.json({ ok: true, count: body.length });
  });

  // Sessiot yksi per tiedosto (sessions/<id>.json): jälki + kiihtyvyysraakadata
  // ovat isoja, eikä koko arkistoa lueta ja kirjoiteta joka uploadilla.
  const SESSION_ID = /^[A-Za-z0-9-]{1,64}$/;
  let sessionsMigrated: Promise<void> | null = null;
  const migrateSessions = () => {
    sessionsMigrated ??= (async () => {
      const legacy = await store.read<SessionSync[] | null>("sessions", null);
      if (!legacy) return;
      for (const session of legacy) {
        if (SESSION_ID.test(session.id)) await store.write(`sessions/${session.id}`, session);
      }
      await store.remove("sessions");
    })();
    return sessionsMigrated;
  };

  app.get("/api/sessions", async (c) => {
    await migrateSessions();
    const ids = await store.list("sessions");
    const sessions = await Promise.all(ids.map((id) => store.read<SessionSync | null>(`sessions/${id}`, null)));
    // Kevyt listaus: ilman jälkeä ja raakadataa.
    const light = sessions
      .filter((s): s is SessionSync => s !== null)
      .map(({ track, motion, ...rest }) => rest)
      .sort((a, b) => (a.startDate < b.startDate ? 1 : -1));
    return c.json(light);
  });

  app.get("/api/sessions/:id", async (c) => {
    await migrateSessions();
    const id = c.req.param("id");
    if (!SESSION_ID.test(id)) return c.json({ error: "kelvoton id" }, 400);
    const session = await store.read<SessionSync | null>(`sessions/${id}`, null);
    if (!session) return c.json({ error: "sessiota ei ole" }, 404);
    return c.json(session);
  });

  app.post("/api/sessions", async (c) => {
    await migrateSessions();
    const body = await readJson<SessionSync>(c);
    if (!body?.id || !body?.startDate) return c.json({ error: "id ja startDate vaaditaan" }, 400);
    if (!SESSION_ID.test(body.id)) return c.json({ error: "kelvoton id" }, 400);
    await store.write(`sessions/${body.id}`, body);
    return c.json({ ok: true });
  });

  // --- Kelivahti ---

  app.get("/api/alerts", async (c) => c.json(await store.read<Alert[]>("alerts", [])));

  app.put("/api/alerts", async (c) => {
    const body = await readJson<Alert[]>(c);
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
    // Hälytykset ovat käyttäjän omia tietueita omalla rajallaan; spotin
    // tuuli-ikkuna ei itsessään hälytä.
    const alerts = (await store.read<Alert[]>("alerts", [])).filter((a) => a?.enabled && Number.isFinite(a.minWind));
    const spots = await store.read<SpotSync[]>("spots", []);
    const results: { alertId: string; spotName: string; windows: AlertWindow[] }[] = [];

    for (const alert of alerts) {
      // Sijainti hälytyksestä itsestään; vanhoissa hälytyksissä spotista.
      const spot = spots.find((s) => s.id === alert.spotId);
      const latitude = alert.latitude ?? spot?.latitude;
      const longitude = alert.longitude ?? spot?.longitude;
      const sea = (alert.waterType ?? spot?.waterType) === "sea";
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
      try {
        const key = `${latitude!.toFixed(3)},${longitude!.toFixed(3)},${sea}`;
        const forecast = await forecastCache.getOrSet(key, () =>
          fetchCombinedForecast(latitude!, longitude!, sea, 3, fetchImpl, now),
        );
        // Vain tulevat tunnit: Open-Meteon päivä alkaa 00 UTC, eikä aamun
        // ikkunasta pidä ilmoittaa iltapäivällä.
        const nowHour = `${now().toISOString().slice(0, 13)}:00`; // käynnissä oleva tunti mukaan
        const windows = matchAlert(alert, forecast.wind.filter((h) => h.time >= nowHour));
        if (windows.length > 0) {
          results.push({ alertId: alert.id, spotName: alert.spotName || spot?.name || "Kelivahti", windows });
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

  /** Open-Meteon UTC-tunti ("2026-08-21T10:00") suomalaiselle lukijalle: "pe 13:00". */
  function formatLocal(isoUtc: string): string {
    const date = new Date(`${isoUtc}:00Z`);
    if (Number.isNaN(date.getTime())) return isoUtc;
    return new Intl.DateTimeFormat("fi-FI", {
      timeZone: "Europe/Helsinki", weekday: "short", hour: "2-digit", minute: "2-digit",
    }).format(date);
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
              `Ennusteessa kelit ${formatLocal(window.start)}–${formatLocal(window.end)} ` +
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
