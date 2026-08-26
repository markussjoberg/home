/**
 * Spotin maastoanalyysi korkeusdatasta (Open-Meteo Elevation API, Copernicus
 * GLO-90 -korkeusmalli, ei avainta). Spotin ympäriltä haetaan korkeusprofiili
 * kahdeksaan ilmansuuntaan yhdellä kutsulla, ja siitä johdetaan per suunta:
 *
 * - **fetch**: matka jonka vesi/tasamaa jatkuu tuulen tulosuuntaan — järviaaltojen
 *   laskennan syöte (JONSWAP fetch-limited appin puolella)
 * - **avoimuus**: 0 = suojainen (maasto nousee heti tuulen yläpuolella),
 *   1 = täysin avoin. Heuristiikka: keskimääräinen nousu ≤ 2 km matkalla,
 *   normalisoituna 25 metriin.
 *
 * Metsänpeite (Luke/Copernicus) olisi seuraava tarkennus — korkeus ajaa
 * asian pitkälle, joten se on vaihetta 2.
 */

/** Näyte-etäisyydet kilometreinä (myös fetchin maksimi = viimeinen). */
export const TRANSECT_DISTANCES_KM = [0.25, 0.5, 1, 2, 3, 5, 8, 12, 20];

export interface OctantMeta {
  /** Ilmansuunta 0 = N … 7 = NW (suunta JOSTA tuuli tulee). */
  octant: number;
  /** Avovettä/tasamaata tuulen yläpuolella (km); 20 = vähintään 20. */
  fetchKm: number;
  /** 0 = suojainen … 1 = avoin. */
  exposure: number;
}

export interface SpotMeta {
  latitude: number;
  longitude: number;
  elevation: number;
  octants: OctantMeta[];
}

/** Siirtää pistettä suuntimaan (asteina) annetun matkan (km). */
export function destinationPoint(lat: number, lon: number, bearingDeg: number, distanceKm: number): { lat: number; lon: number } {
  const R = 6371;
  const delta = distanceKm / R;
  const theta = (bearingDeg * Math.PI) / 180;
  const phi1 = (lat * Math.PI) / 180;
  const lambda1 = (lon * Math.PI) / 180;
  const phi2 = Math.asin(
    Math.sin(phi1) * Math.cos(delta) + Math.cos(phi1) * Math.sin(delta) * Math.cos(theta),
  );
  const lambda2 =
    lambda1 +
    Math.atan2(
      Math.sin(theta) * Math.sin(delta) * Math.cos(phi1),
      Math.cos(delta) - Math.sin(phi1) * Math.sin(phi2),
    );
  return { lat: (phi2 * 180) / Math.PI, lon: (((lambda2 * 180) / Math.PI + 540) % 360) - 180 };
}

/** Fetch ja avoimuus yhdestä korkeusprofiilista (spotin korkeus e0). */
export function analyzeTransect(
  e0: number,
  elevations: number[],
  riseThreshold = 4.0,
  shelterNorm = 25.0,
): { fetchKm: number; exposure: number } {
  let fetchKm = 0;
  for (let i = 0; i < TRANSECT_DISTANCES_KM.length && i < elevations.length; i++) {
    if (elevations[i]! <= e0 + riseThreshold) {
      fetchKm = TRANSECT_DISTANCES_KM[i]!;
    } else {
      break;
    }
  }
  const near: number[] = [];
  for (let i = 0; i < elevations.length; i++) {
    if (TRANSECT_DISTANCES_KM[i]! <= 2.0) near.push(elevations[i]! - e0);
  }
  const rise = Math.max(0, near.reduce((a, b) => a + b, 0) / Math.max(1, near.length));
  const exposure = 1 - Math.min(1, rise / shelterNorm);
  return { fetchKm, exposure: Math.round(exposure * 100) / 100 };
}

/** Kaikki näytepisteet yhteen kutsuun: [spotti, sitten 8 suuntaa × etäisyydet]. */
export function transectPoints(lat: number, lon: number): { lat: number; lon: number }[] {
  const points = [{ lat, lon }];
  for (let octant = 0; octant < 8; octant++) {
    const bearing = octant * 45;
    for (const distance of TRANSECT_DISTANCES_KM) {
      points.push(destinationPoint(lat, lon, bearing, distance));
    }
  }
  return points;
}

export function buildElevationUrl(points: { lat: number; lon: number }[]): string {
  const url = new URL("https://api.open-meteo.com/v1/elevation");
  url.searchParams.set("latitude", points.map((p) => p.lat.toFixed(5)).join(","));
  url.searchParams.set("longitude", points.map((p) => p.lon.toFixed(5)).join(","));
  return url.toString();
}

export interface FetchJsonLike {
  (url: string): Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;
}

export async function fetchSpotMeta(
  lat: number,
  lon: number,
  fetchImpl: FetchJsonLike = fetch,
): Promise<SpotMeta> {
  const points = transectPoints(lat, lon);
  const res = await fetchImpl(buildElevationUrl(points));
  if (!res.ok) throw new Error(`elevation ${res.status}`);
  const body = (await res.json()) as { elevation?: number[] };
  const elevations = body.elevation ?? [];
  if (elevations.length !== points.length) {
    throw new Error(`elevation: odotettiin ${points.length} pistettä, saatiin ${elevations.length}`);
  }

  const e0 = elevations[0]!;
  const perDirection = TRANSECT_DISTANCES_KM.length;
  const octants: OctantMeta[] = [];
  for (let octant = 0; octant < 8; octant++) {
    const slice = elevations.slice(1 + octant * perDirection, 1 + (octant + 1) * perDirection);
    const { fetchKm, exposure } = analyzeTransect(e0, slice);
    octants.push({ octant, fetchKm, exposure });
  }
  return { latitude: lat, longitude: lon, elevation: e0, octants };
}
