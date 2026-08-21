/**
 * Open-Meteo-haku ja vastausten yhdistäminen appin ennustemuotoon.
 * Puhtaat funktiot (buildForecastUrl, mergeForecast) on eriytetty testattaviksi.
 */

export interface WindHour {
  /** "yyyy-MM-ddTHH:mm" UTC — sama muoto jota appi parsii. */
  time: string;
  speed: number;
  gust: number;
  direction: number;
}

export interface WaveHour {
  time: string;
  height: number;
  period: number;
  direction: number;
}

export interface CombinedForecast {
  latitude: number;
  longitude: number;
  fetchedAt: string;
  wind: WindHour[];
  waves: WaveHour[] | null;
}

interface OpenMeteoWindResponse {
  hourly?: {
    time?: string[];
    wind_speed_10m?: (number | null)[];
    wind_gusts_10m?: (number | null)[];
    wind_direction_10m?: (number | null)[];
  };
}

interface OpenMeteoMarineResponse {
  hourly?: {
    time?: string[];
    wave_height?: (number | null)[];
    wave_period?: (number | null)[];
    wave_direction?: (number | null)[];
  };
}

export function buildWindUrl(lat: number, lon: number, days: number): string {
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.searchParams.set("latitude", lat.toFixed(4));
  url.searchParams.set("longitude", lon.toFixed(4));
  url.searchParams.set("hourly", "wind_speed_10m,wind_gusts_10m,wind_direction_10m");
  url.searchParams.set("wind_speed_unit", "ms");
  url.searchParams.set("timezone", "UTC");
  url.searchParams.set("forecast_days", String(days));
  return url.toString();
}

export function buildMarineUrl(lat: number, lon: number, days: number): string {
  const url = new URL("https://marine-api.open-meteo.com/v1/marine");
  url.searchParams.set("latitude", lat.toFixed(4));
  url.searchParams.set("longitude", lon.toFixed(4));
  url.searchParams.set("hourly", "wave_height,wave_period,wave_direction");
  url.searchParams.set("timezone", "UTC");
  url.searchParams.set("forecast_days", String(days));
  return url.toString();
}

export function parseWind(body: OpenMeteoWindResponse): WindHour[] {
  const h = body.hourly;
  if (!h?.time) return [];
  const result: WindHour[] = [];
  h.time.forEach((time, i) => {
    const speed = h.wind_speed_10m?.[i];
    const gust = h.wind_gusts_10m?.[i];
    const direction = h.wind_direction_10m?.[i];
    if (speed == null || gust == null || direction == null) return;
    result.push({ time, speed, gust, direction });
  });
  return result;
}

export function parseWaves(body: OpenMeteoMarineResponse): WaveHour[] {
  const h = body.hourly;
  if (!h?.time) return [];
  const result: WaveHour[] = [];
  h.time.forEach((time, i) => {
    const height = h.wave_height?.[i];
    const period = h.wave_period?.[i];
    const direction = h.wave_direction?.[i];
    if (height == null || period == null || direction == null) return;
    result.push({ time, height, period, direction });
  });
  return result;
}

export interface FetchLike {
  (url: string): Promise<{ ok: boolean; status: number; json(): Promise<unknown>; }>;
}

/** Hakee tuulen (aina) ja aallokon (sea=true; epäonnistuminen ei kaada tuulta). */
export async function fetchCombinedForecast(
  lat: number,
  lon: number,
  sea: boolean,
  days = 3,
  fetchImpl: FetchLike = fetch,
  now: () => Date = () => new Date(),
): Promise<CombinedForecast> {
  const windPromise = fetchImpl(buildWindUrl(lat, lon, days)).then(async (res) => {
    if (!res.ok) throw new Error(`open-meteo ${res.status}`);
    return parseWind((await res.json()) as OpenMeteoWindResponse);
  });

  let waves: WaveHour[] | null = null;
  if (sea) {
    waves = await fetchImpl(buildMarineUrl(lat, lon, days))
      .then(async (res) => (res.ok ? parseWaves((await res.json()) as OpenMeteoMarineResponse) : null))
      .catch(() => null);
  }

  return {
    latitude: lat,
    longitude: lon,
    fetchedAt: now().toISOString(),
    wind: await windPromise,
    waves,
  };
}
