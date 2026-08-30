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

/** Kysely: rantarakenteet ja -infra lähisäteellä, palvelut (parkki, vessa,
 *  kioski) pienemmällä. */
export function overpassQuery(lat: number, lon: number, radiusM = 1500, serviceRadiusM = 800): string {
  const a = `around:${radiusM},${lat.toFixed(5)},${lon.toFixed(5)}`;
  const s = `around:${serviceRadiusM},${lat.toFixed(5)},${lon.toFixed(5)}`;
  return `[out:json][timeout:25];(
    nwr["natural"="beach"](${a});
    nwr["man_made"="pier"](${a});
    nwr["leisure"="slipway"](${a});
    nwr["leisure"="marina"](${a});
    nwr["leisure"="sauna"](${a});
    nwr["leisure"="firepit"](${a});
    nwr["amenity"="bbq"](${a});
    nwr["amenity"="shelter"](${a});
    nwr["amenity"="shower"](${a});
    nwr["amenity"="dressing_room"](${a});
    nwr["amenity"="drinking_water"](${s});
    nwr["amenity"="parking"](${s});
    nwr["amenity"="toilets"](${s});
    nwr["shop"="kiosk"](${s});
  );out center 250;`;
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
  if (tags.leisure === "sauna") return "Sauna";
  if (tags.leisure === "firepit" || tags.amenity === "bbq") return "Grillipaikka";
  if (tags.amenity === "shelter") return "Katos/laavu";
  if (tags.amenity === "shower") return "Suihku";
  if (tags.amenity === "dressing_room") return "Pukukoppi";
  if (tags.amenity === "drinking_water") return "Juomavesi";
  if (tags.amenity === "parking") return "Pysäköinti";
  if (tags.amenity === "toilets") return "WC";
  if (tags.shop === "kiosk") return "Kioski";
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

/** Lipas-tyyppikoodit (tarkistettu api.lipas.fi/v1/sports-place-types 2026-08).
 *  Sama kategorianimi kuin OSM:ssä yhdistyy nearestPerCategoryssa —
 *  lähde näkyy Place.source-kentästä. */
export const LIPAS_TYPE_NAMES: Record<number, string> = {
  203: "Veneilyn palvelupaikka",
  3220: "Uimaranta",
  3230: "Uimapaikka",
  5150: "Melontakeskus",
};

export function lipasUrl(base: string, lat: number, lon: number, distanceKm = 3): string {
  const url = new URL(`${base.replace(/\/$/, "")}/sports-places`);
  url.searchParams.set("closeToLat", lat.toFixed(5));
  url.searchParams.set("closeToLon", lon.toFixed(5));
  url.searchParams.set("closeToDistanceKm", String(distanceKm));
  for (const code of Object.keys(LIPAS_TYPE_NAMES)) {
    url.searchParams.append("typeCodes", code);
  }
  // v1 palauttaa oletuksena vain id:t — kentät on pyydettävä erikseen.
  for (const field of ["name", "type.typeCode", "location.coordinates.wgs84"]) {
    url.searchParams.append("fields", field);
  }
  url.searchParams.set("pageSize", "50");
  return url.toString();
}

interface LipasPlace {
  name?: string;
  type?: { typeCode?: number };
  location?: { coordinates?: { wgs84?: { lat?: number; lon?: number } } };
}

/** Parsii Lipas-vastauksen kohteet ilman etäisyyttä (peiliä varten). */
export function parseLipasItems(body: unknown): Omit<Place, "distanceM" | "source">[] {
  const items = Array.isArray(body) ? (body as LipasPlace[]) : [];
  const places: Omit<Place, "distanceM" | "source">[] = [];
  for (const item of items) {
    const coords = item.location?.coordinates?.wgs84;
    const typeCode = item.type?.typeCode;
    if (!coords?.lat || !coords?.lon || !typeCode) continue;
    const category = LIPAS_TYPE_NAMES[typeCode];
    if (!category) continue;
    places.push({ category, name: item.name ?? null, latitude: coords.lat, longitude: coords.lon });
  }
  return places;
}

export function parseLipas(body: unknown, lat: number, lon: number): Place[] {
  return parseLipasItems(body).map((place) => ({
    ...place,
    distanceM: Math.round(haversineMeters(lat, lon, place.latitude, place.longitude)),
    source: "lipas" as const,
  }));
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

/** OSM-paikat Overpassista; virhe tai ei-ok → tyhjä lista. */
export async function fetchOsmPlaces(lat: number, lon: number, fetchImpl: FetchLike = fetch, radiusM = 1500): Promise<Place[]> {
  try {
    const res = await fetchImpl(OVERPASS_URL, {
      method: "POST",
      body: `data=${encodeURIComponent(overpassQuery(lat, lon, radiusM, Math.min(radiusM, 1500)))}`,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        // Overpass vastaa 406 ilman tunnistautuvaa User-Agentia.
        "User-Agent": "noste-server/0.1 (https://aihiolabs.com/noste)",
      },
    });
    return res.ok ? parseOverpass(await res.json(), lat, lon) : [];
  } catch {
    return [];
  }
}

/** Lipas-paikat suoraan rajapinnasta (fallback, kun peili on tyhjä). */
export async function fetchLipasPlaces(
  lat: number,
  lon: number,
  lipasBase: string,
  fetchImpl: FetchLike = fetch,
): Promise<Place[]> {
  try {
    const res = await fetchImpl(lipasUrl(lipasBase, lat, lon));
    return res.ok ? parseLipas(await res.json(), lat, lon) : [];
  } catch {
    return [];
  }
}

/** Hakee OSM + Lipas -paikat; toisen lähteen virhe ei kaada toista. */
export async function fetchPlaces(
  lat: number,
  lon: number,
  lipasBase: string,
  fetchImpl: FetchLike = fetch,
): Promise<{ nearest: Place[]; all: Place[] }> {
  const [osm, lipas] = await Promise.all([
    fetchOsmPlaces(lat, lon, fetchImpl),
    fetchLipasPlaces(lat, lon, lipasBase, fetchImpl),
  ]);
  const all = [...osm, ...lipas];
  all.sort((a, b) => a.distanceM - b.distanceM);
  return { nearest: nearestPerCategory(all), all };
}
