/**
 * Rantainfo: uimarannat, laiturit, luiskat, satamat, parkit ja vessat OSM:stä
 * (Overpass API) sekä uimarannat/-paikat Lipaksesta (Jyväskylän yliopiston
 * avoin liikuntapaikkarekisteri). Palautetaan kategorioittain etäisyyksineen.
 */

export interface Place {
  category: string;
  name: string | null;
  latitude: number;
  longitude: number;
  distanceM: number;
  source: "osm" | "lipas";
}

export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r = 6371000;
  const p1 = (lat1 * Math.PI) / 180;
  const p2 = (lat2 * Math.PI) / 180;
  const dp = ((lat2 - lat1) * Math.PI) / 180;
  const dl = ((lon2 - lon1) * Math.PI) / 180;
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// --- OSM / Overpass ---

export const OVERPASS_URL = "https://overpass-api.de/api/interpreter";

/** Kysely: rantarakenteet lähisäteellä, palvelut (parkki, vessa) pienemmällä. */
export function overpassQuery(lat: number, lon: number, radiusM = 1500, serviceRadiusM = 800): string {
  const a = `around:${radiusM},${lat.toFixed(5)},${lon.toFixed(5)}`;
  const s = `around:${serviceRadiusM},${lat.toFixed(5)},${lon.toFixed(5)}`;
  return `[out:json][timeout:25];(
    nwr["natural"="beach"](${a});
    nwr["man_made"="pier"](${a});
    nwr["leisure"="slipway"](${a});
    nwr["leisure"="marina"](${a});
    nwr["amenity"="parking"](${s});
    nwr["amenity"="toilets"](${s});
  );out center 80;`;
}

interface OverpassElement {
  type: string;
  lat?: number;
  lon?: number;
  center?: { lat: number; lon: number };
  tags?: Record<string, string>;
}

function categorize(tags: Record<string, string>): string | null {
  if (tags.natural === "beach") return "Uimaranta";
  if (tags.man_made === "pier") return "Laituri";
  if (tags.leisure === "slipway") return "Veneluiska";
  if (tags.leisure === "marina") return "Satama";
  if (tags.amenity === "parking") return "Pysäköinti";
  if (tags.amenity === "toilets") return "WC";
  return null;
}

export function parseOverpass(body: unknown, lat: number, lon: number): Place[] {
  const elements = (body as { elements?: OverpassElement[] })?.elements ?? [];
  const places: Place[] = [];
  for (const element of elements) {
    const tags = element.tags ?? {};
    const category = categorize(tags);
    const position = element.lat !== undefined && element.lon !== undefined
      ? { lat: element.lat, lon: element.lon }
      : element.center;
    if (!category || !position) continue;
    places.push({
      category,
      name: tags.name ?? null,
      latitude: position.lat,
      longitude: position.lon,
      distanceM: Math.round(haversineMeters(lat, lon, position.lat, position.lon)),
      source: "osm",
    });
  }
  return places;
}

// --- Lipas ---

/** Lipas-tyyppikoodit: 3220 uimaranta, 3230 uimapaikka. */
export const LIPAS_TYPE_NAMES: Record<number, string> = {
  3220: "Uimaranta (Lipas)",
  3230: "Uimapaikka (Lipas)",
};

export function lipasUrl(base: string, lat: number, lon: number, distanceKm = 3): string {
  const url = new URL(`${base.replace(/\/$/, "")}/sports-places`);
  url.searchParams.set("closeToLat", lat.toFixed(5));
  url.searchParams.set("closeToLon", lon.toFixed(5));
  url.searchParams.set("closeToDistanceKm", String(distanceKm));
  for (const code of Object.keys(LIPAS_TYPE_NAMES)) {
    url.searchParams.append("typeCodes", code);
  }
  url.searchParams.set("pageSize", "30");
  return url.toString();
}

interface LipasPlace {
  name?: string;
  type?: { typeCode?: number };
  location?: { coordinates?: { wgs84?: { lat?: number; lon?: number } } };
}

export function parseLipas(body: unknown, lat: number, lon: number): Place[] {
  const items = Array.isArray(body) ? (body as LipasPlace[]) : [];
  const places: Place[] = [];
  for (const item of items) {
    const coords = item.location?.coordinates?.wgs84;
    const typeCode = item.type?.typeCode;
    if (!coords?.lat || !coords?.lon || !typeCode) continue;
    const category = LIPAS_TYPE_NAMES[typeCode];
    if (!category) continue;
    places.push({
      category,
      name: item.name ?? null,
      latitude: coords.lat,
      longitude: coords.lon,
      distanceM: Math.round(haversineMeters(lat, lon, coords.lat, coords.lon)),
      source: "lipas",
    });
  }
  return places;
}

/** Lähin per kategoria, etäisyysjärjestyksessä. */
export function nearestPerCategory(places: Place[]): Place[] {
  const best = new Map<string, Place>();
  for (const place of places) {
    const existing = best.get(place.category);
    if (!existing || place.distanceM < existing.distanceM) {
      best.set(place.category, place);
    }
  }
  return [...best.values()].sort((a, b) => a.distanceM - b.distanceM);
}

export interface FetchLike {
  (url: string, init?: { method?: string; body?: string; headers?: Record<string, string> }): Promise<{
    ok: boolean;
    status: number;
    json(): Promise<unknown>;
  }>;
}

/** Hakee OSM + Lipas -paikat; toisen lähteen virhe ei kaada toista. */
export async function fetchPlaces(
  lat: number,
  lon: number,
  lipasBase: string,
  fetchImpl: FetchLike = fetch,
): Promise<{ nearest: Place[]; all: Place[] }> {
  const results = await Promise.allSettled([
    fetchImpl(OVERPASS_URL, {
      method: "POST",
      body: `data=${encodeURIComponent(overpassQuery(lat, lon))}`,
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    }).then(async (res) => (res.ok ? parseOverpass(await res.json(), lat, lon) : [])),
    fetchImpl(lipasUrl(lipasBase, lat, lon)).then(async (res) =>
      res.ok ? parseLipas(await res.json(), lat, lon) : [],
    ),
  ]);
  const all = results.flatMap((r) => (r.status === "fulfilled" ? r.value : []));
  all.sort((a, b) => a.distanceM - b.distanceM);
  return { nearest: nearestPerCategory(all), all };
}
