/**
 * FMI:n avoin data: toteutunut tuuli lähimmältä havaintoasemalta (WFS, ei avainta).
 * Vastaus on BsWfs-XML; parsitaan kevyesti ilman XML-riippuvuutta — rakenne on
 * vakaa ja yksinkertainen (yksi ParameterName/ParameterValue per elementti).
 */

export interface WindObservation {
  /** ISO-aikaleima (UTC). */
  time: string;
  latitude: number;
  longitude: number;
  windSpeed: number | null;
  windGust: number | null;
  windDirection: number | null;
  /** Ilman lämpötila °C (t2m); null jos asema ei mittaa. */
  airTemp: number | null;
}

export function buildObservationUrl(lat: number, lon: number, now: () => Date = () => new Date()): string {
  const start = new Date(now().getTime() - 60 * 60 * 1000); // viimeinen tunti
  const url = new URL("https://opendata.fmi.fi/wfs");
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", "2.0.0");
  url.searchParams.set("request", "getFeature");
  url.searchParams.set("storedquery_id", "fmi::observations::weather::simple");
  url.searchParams.set("latlon", `${lat.toFixed(4)},${lon.toFixed(4)}`);
  url.searchParams.set("maxlocations", "1");
  url.searchParams.set("parameters", "ws_10min,wg_10min,wd_10min,t2m");
  url.searchParams.set("starttime", start.toISOString());
  return url.toString();
}

export interface RawElement {
  time: string;
  lat: number;
  lon: number;
  name: string;
  value: number;
}

export function parseElements(xml: string): RawElement[] {
  const result: RawElement[] = [];
  const blocks = xml.match(/<BsWfs:BsWfsElement[\s\S]*?<\/BsWfs:BsWfsElement>/g) ?? [];
  for (const block of blocks) {
    const pos = block.match(/<gml:pos>\s*([\d.-]+)\s+([\d.-]+)\s*<\/gml:pos>/);
    const time = block.match(/<BsWfs:Time>([^<]+)<\/BsWfs:Time>/);
    const name = block.match(/<BsWfs:ParameterName>([^<]+)<\/BsWfs:ParameterName>/);
    const value = block.match(/<BsWfs:ParameterValue>([^<]+)<\/BsWfs:ParameterValue>/);
    if (!pos || !time || !name || !value) continue;
    const numeric = Number(value[1]);
    if (!Number.isFinite(numeric)) continue; // NaN = puuttuva havainto
    result.push({
      time: time[1]!,
      lat: Number(pos[1]),
      lon: Number(pos[2]),
      name: name[1]!,
      value: numeric,
    });
  }
  return result;
}

/** Poimii tuoreimman täyden havainnon (ws/wg/wd samalta aikaleimalta). */
export function parseLatestObservation(xml: string): WindObservation | null {
  const elements = parseElements(xml);
  if (elements.length === 0) return null;

  const byTime = new Map<string, RawElement[]>();
  for (const element of elements) {
    const list = byTime.get(element.time) ?? [];
    list.push(element);
    byTime.set(element.time, list);
  }

  const times = [...byTime.keys()].sort();
  for (let i = times.length - 1; i >= 0; i--) {
    const list = byTime.get(times[i]!)!;
    const find = (name: string) => list.find((e) => e.name === name)?.value ?? null;
    const observation: WindObservation = {
      time: times[i]!,
      latitude: list[0]!.lat,
      longitude: list[0]!.lon,
      windSpeed: find("ws_10min"),
      windGust: find("wg_10min"),
      windDirection: find("wd_10min"),
      airTemp: find("t2m"),
    };
    if (observation.windSpeed !== null) return observation;
  }
  return null;
}

export interface FetchTextLike {
  (url: string): Promise<{ ok: boolean; status: number; text(): Promise<string>; }>;
}

export async function fetchLatestObservation(
  lat: number,
  lon: number,
  fetchImpl: FetchTextLike = fetch,
): Promise<WindObservation | null> {
  const res = await fetchImpl(buildObservationUrl(lat, lon));
  if (!res.ok) throw new Error(`fmi ${res.status}`);
  return parseLatestObservation(await res.text());
}
