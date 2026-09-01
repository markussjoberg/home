/**
 * Aaltokenttä kartalle: karkea hila näkyvälle alueelle Open-Meteon marine-
 * mallista yhdellä monipistekutsulla (sama resepti kuin tuulikentässä).
 * Maapisteet tulevat null-arvoina ja karsitaan — kenttä kattaa vain vettä,
 * joten appi voi värjätä aallonkorkeuden suoraan merialueen päälle.
 */
import type { FetchLike } from "./places.js";
import { GRID_SIZE } from "./windfield.js";

export interface WaveCell {
  latitude: number;
  longitude: number;
  /** Merkitsevä aallonkorkeus (m). */
  height: number;
  /** Aaltojen tulosuunta (°). */
  direction: number;
  /** Aaltoperiodi (s). */
  period: number;
}

/**
 * Aaltomallin hila on karkea (~5–10 km), joten pienelle näkymälle Open-Meteo
 * palauttaisi kaikille 81 pisteelle saman solun. Alue laajennetaan
 * vähimmäiskokoon keskipisteen ympärille — appi saa käytetyn alueen mukana.
 */
export const MIN_WAVE_SPAN_LAT = 0.6;
export const MIN_WAVE_SPAN_LON = 1.2;

export type BBox = [minLon: number, minLat: number, maxLon: number, maxLat: number];

export function expandWaveBBox(minLon: number, minLat: number, maxLon: number, maxLat: number): BBox {
  const midLat = (minLat + maxLat) / 2;
  const midLon = (minLon + maxLon) / 2;
  const halfLat = Math.max(maxLat - minLat, MIN_WAVE_SPAN_LAT) / 2;
  const halfLon = Math.max(maxLon - minLon, MIN_WAVE_SPAN_LON) / 2;
  return [midLon - halfLon, midLat - halfLat, midLon + halfLon, midLat + halfLat];
}

export function buildWaveFieldUrl(minLon: number, minLat: number, maxLon: number, maxLat: number): string {
  const lats: string[] = [];
  const lons: string[] = [];
  for (let row = 0; row < GRID_SIZE; row++) {
    for (let col = 0; col < GRID_SIZE; col++) {
      lats.push((minLat + ((maxLat - minLat) * row) / (GRID_SIZE - 1)).toFixed(3));
      lons.push((minLon + ((maxLon - minLon) * col) / (GRID_SIZE - 1)).toFixed(3));
    }
  }
  const url = new URL("https://marine-api.open-meteo.com/v1/marine");
  url.searchParams.set("latitude", lats.join(","));
  url.searchParams.set("longitude", lons.join(","));
  url.searchParams.set("current", "wave_height,wave_direction,wave_period");
  return url.toString();
}

interface OpenMeteoMarinePoint {
  latitude: number;
  longitude: number;
  current?: {
    wave_height?: number | null;
    wave_direction?: number | null;
    wave_period?: number | null;
  };
}

/** Maapisteet (null) karsitaan; samaan mallisoluun osuneet pyynnöt yhdistetään. */
export function parseWaveField(body: unknown): WaveCell[] {
  const points = Array.isArray(body) ? (body as OpenMeteoMarinePoint[]) : [body as OpenMeteoMarinePoint];
  const cells: WaveCell[] = [];
  const seen = new Set<string>();
  for (const point of points) {
    const height = point?.current?.wave_height;
    const direction = point?.current?.wave_direction;
    const period = point?.current?.wave_period;
    if (typeof height !== "number" || typeof direction !== "number") continue;
    const key = `${point.latitude},${point.longitude}`;
    if (seen.has(key)) continue;
    seen.add(key);
    cells.push({
      latitude: point.latitude,
      longitude: point.longitude,
      height,
      direction,
      period: typeof period === "number" ? period : 0,
    });
  }
  return cells;
}

export interface WaveFieldResult {
  cells: WaveCell[];
  /** Todellinen haettu alue (laajennettu vähimmäiskokoon). */
  bbox: BBox;
}

export async function fetchWaveField(
  minLon: number, minLat: number, maxLon: number, maxLat: number,
  fetchImpl: FetchLike = fetch,
): Promise<WaveFieldResult> {
  const bbox = expandWaveBBox(minLon, minLat, maxLon, maxLat);
  const res = await fetchImpl(buildWaveFieldUrl(...bbox));
  if (!res.ok) return { cells: [], bbox };
  return { cells: parseWaveField(await res.json()), bbox };
}
