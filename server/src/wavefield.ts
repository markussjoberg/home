/**
 * Aaltokenttä kartalle: karkea hila näkyvälle alueelle Open-Meteon marine-
 * mallista yhdellä monipistekutsulla, kaikille ennustetunneille (sama resepti
 * kuin tuulikentässä). Maapisteet tulevat null-arvoina ja karsitaan — kenttä
 * kattaa vain vettä, joten appi voi värjätä aallonkorkeuden merialueen päälle.
 */
import type { FetchLike } from "./places.js";
import { FIELD_FORECAST_DAYS, gridPoints } from "./windfield.js";

export interface WaveCellSeries {
  latitude: number;
  longitude: number;
  /** Merkitsevä aallonkorkeus (m) per tunti — indeksi vastaa `times`-taulukkoa. */
  height: number[];
  /** Aaltojen tulosuunta (°) per tunti. */
  direction: number[];
  /** Aaltoperiodi (s) per tunti; 0 jos malli ei anna. */
  period: number[];
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
  const { lats, lons } = gridPoints(minLon, minLat, maxLon, maxLat);
  const url = new URL("https://marine-api.open-meteo.com/v1/marine");
  url.searchParams.set("latitude", lats.join(","));
  url.searchParams.set("longitude", lons.join(","));
  url.searchParams.set("hourly", "wave_height,wave_direction,wave_period");
  url.searchParams.set("timezone", "UTC");
  url.searchParams.set("forecast_days", String(FIELD_FORECAST_DAYS));
  return url.toString();
}

interface OpenMeteoMarinePoint {
  latitude: number;
  longitude: number;
  hourly?: {
    time?: string[];
    wave_height?: (number | null)[];
    wave_direction?: (number | null)[];
    wave_period?: (number | null)[];
  };
}

export interface WaveFieldSeries {
  times: string[];
  cells: WaveCellSeries[];
  /** Todellinen haettu alue (laajennettu vähimmäiskokoon). */
  bbox: BBox;
}

/**
 * Maapisteet (kaikki null) karsitaan; samaan mallisoluun osuneet pyynnöt
 * yhdistetään. Yksittäinen puuttuva tunti täytetään edellisestä, jotta
 * aikajana ei katkea.
 */
export function parseWaveField(body: unknown): { times: string[]; cells: WaveCellSeries[] } {
  const points = Array.isArray(body) ? (body as OpenMeteoMarinePoint[]) : [body as OpenMeteoMarinePoint];
  const times = points[0]?.hourly?.time ?? [];
  const cells: WaveCellSeries[] = [];
  const seen = new Set<string>();
  for (const point of points) {
    const heights = point?.hourly?.wave_height;
    const directions = point?.hourly?.wave_direction;
    if (!heights || !directions || heights.length !== times.length || directions.length !== times.length) continue;
    if (!heights.some((v) => typeof v === "number")) continue; // maapiste
    const key = `${point.latitude},${point.longitude}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const periods = point.hourly?.wave_period ?? [];
    const height: number[] = [];
    const direction: number[] = [];
    const period: number[] = [];
    for (let i = 0; i < times.length; i++) {
      const h = heights[i];
      const d = directions[i];
      height.push(typeof h === "number" ? h : (height[i - 1] ?? 0));
      direction.push(typeof d === "number" ? d : (direction[i - 1] ?? 0));
      const p = periods[i];
      period.push(typeof p === "number" ? p : (period[i - 1] ?? 0));
    }
    cells.push({ latitude: point.latitude, longitude: point.longitude, height, direction, period });
  }
  return { times, cells };
}

export async function fetchWaveField(
  minLon: number, minLat: number, maxLon: number, maxLat: number,
  fetchImpl: FetchLike = fetch,
): Promise<WaveFieldSeries> {
  const bbox = expandWaveBBox(minLon, minLat, maxLon, maxLat);
  const res = await fetchImpl(buildWaveFieldUrl(...bbox));
  if (!res.ok) return { times: [], cells: [], bbox };
  return { ...parseWaveField(await res.json()), bbox };
}
