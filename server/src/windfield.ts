/**
 * Tuulikenttä kartalle (Windy-tyylinen partikkelianimaatio appissa):
 * karkea hila näkyvälle alueelle Open-Meteon monipistehaulla — koko kenttä
 * yhdellä kutsulla. Appi advektoi partikkelit kentässä asiakaspäässä.
 */
import type { FetchLike } from "./places.js";

export interface WindCell {
  latitude: number;
  longitude: number;
  /** Tuulen nopeus (m/s) ja suunta josta tuulee (°). */
  speed: number;
  direction: number;
}

export const GRID_SIZE = 9;

export function buildWindFieldUrl(minLon: number, minLat: number, maxLon: number, maxLat: number): string {
  const lats: string[] = [];
  const lons: string[] = [];
  for (let row = 0; row < GRID_SIZE; row++) {
    for (let col = 0; col < GRID_SIZE; col++) {
      lats.push((minLat + ((maxLat - minLat) * row) / (GRID_SIZE - 1)).toFixed(3));
      lons.push((minLon + ((maxLon - minLon) * col) / (GRID_SIZE - 1)).toFixed(3));
    }
  }
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.searchParams.set("latitude", lats.join(","));
  url.searchParams.set("longitude", lons.join(","));
  url.searchParams.set("current", "wind_speed_10m,wind_direction_10m");
  url.searchParams.set("wind_speed_unit", "ms");
  return url.toString();
}

interface OpenMeteoPoint {
  latitude: number;
  longitude: number;
  current?: { wind_speed_10m?: number; wind_direction_10m?: number };
}

export function parseWindField(body: unknown): WindCell[] {
  const points = Array.isArray(body) ? (body as OpenMeteoPoint[]) : [body as OpenMeteoPoint];
  const cells: WindCell[] = [];
  for (const point of points) {
    const speed = point?.current?.wind_speed_10m;
    const direction = point?.current?.wind_direction_10m;
    if (typeof speed !== "number" || typeof direction !== "number") continue;
    cells.push({ latitude: point.latitude, longitude: point.longitude, speed, direction });
  }
  return cells;
}

export async function fetchWindField(
  minLon: number, minLat: number, maxLon: number, maxLat: number,
  fetchImpl: FetchLike = fetch,
): Promise<WindCell[]> {
  const res = await fetchImpl(buildWindFieldUrl(minLon, minLat, maxLon, maxLat));
  if (!res.ok) return [];
  return parseWindField(await res.json());
}
