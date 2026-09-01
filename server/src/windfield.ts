/**
 * Tuulikenttä kartalle (Windy-tyylinen partikkelianimaatio appissa):
 * karkea hila näkyvälle alueelle Open-Meteon monipistehaulla — koko kenttä
 * kaikille ennustetunneille yhdellä kutsulla. Appi advektoi partikkelit
 * kentässä asiakaspäässä ja selaa tunteja aikajanalla ilman uusia hakuja.
 */
import type { FetchLike } from "./places.js";

export const GRID_SIZE = 9;
/** Ennustetunnit (Open-Meteo forecast_days); 4 vrk = 96 h aikajanalle. */
export const FIELD_FORECAST_DAYS = 4;

export interface WindCellSeries {
  latitude: number;
  longitude: number;
  /** Tuulen nopeus (m/s) per tunti — indeksi vastaa `times`-taulukkoa. */
  speed: number[];
  /** Suunta josta tuulee (°) per tunti. */
  direction: number[];
}

export interface WindFieldSeries {
  /** Tunnit ISO-muodossa (UTC, ilman Z:aa kuten Open-Meteo antaa). */
  times: string[];
  cells: WindCellSeries[];
}

/** Hilan pisteet rivi kerrallaan (etelästä pohjoiseen, lännestä itään). */
export function gridPoints(minLon: number, minLat: number, maxLon: number, maxLat: number): { lats: string[]; lons: string[] } {
  const lats: string[] = [];
  const lons: string[] = [];
  for (let row = 0; row < GRID_SIZE; row++) {
    for (let col = 0; col < GRID_SIZE; col++) {
      lats.push((minLat + ((maxLat - minLat) * row) / (GRID_SIZE - 1)).toFixed(3));
      lons.push((minLon + ((maxLon - minLon) * col) / (GRID_SIZE - 1)).toFixed(3));
    }
  }
  return { lats, lons };
}

export function buildWindFieldUrl(minLon: number, minLat: number, maxLon: number, maxLat: number): string {
  const { lats, lons } = gridPoints(minLon, minLat, maxLon, maxLat);
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.searchParams.set("latitude", lats.join(","));
  url.searchParams.set("longitude", lons.join(","));
  url.searchParams.set("hourly", "wind_speed_10m,wind_direction_10m");
  url.searchParams.set("wind_speed_unit", "ms");
  url.searchParams.set("timezone", "UTC");
  url.searchParams.set("forecast_days", String(FIELD_FORECAST_DAYS));
  return url.toString();
}

interface OpenMeteoPoint {
  latitude: number;
  longitude: number;
  hourly?: { time?: string[]; wind_speed_10m?: (number | null)[]; wind_direction_10m?: (number | null)[] };
}

/**
 * Yhteinen aikataulukko otetaan ensimmäisestä pisteestä; pisteet joilta
 * puuttuu arvoja karsitaan kokonaan (aukot rikkoisivat animaation).
 */
export function parseWindField(body: unknown): WindFieldSeries {
  const points = Array.isArray(body) ? (body as OpenMeteoPoint[]) : [body as OpenMeteoPoint];
  const times = points[0]?.hourly?.time ?? [];
  const cells: WindCellSeries[] = [];
  for (const point of points) {
    const speed = point?.hourly?.wind_speed_10m;
    const direction = point?.hourly?.wind_direction_10m;
    if (!speed || !direction || speed.length !== times.length || direction.length !== times.length) continue;
    if (speed.some((v) => typeof v !== "number") || direction.some((v) => typeof v !== "number")) continue;
    cells.push({
      latitude: point.latitude,
      longitude: point.longitude,
      speed: speed as number[],
      direction: direction as number[],
    });
  }
  return { times, cells };
}

export async function fetchWindField(
  minLon: number, minLat: number, maxLon: number, maxLat: number,
  fetchImpl: FetchLike = fetch,
): Promise<WindFieldSeries> {
  const res = await fetchImpl(buildWindFieldUrl(minLon, minLat, maxLon, maxLat));
  if (!res.ok) return { times: [], cells: [] };
  return parseWindField(await res.json());
}
