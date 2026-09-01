/**
 * FMI:n meriaaltodata: aaltopoijujen havainnot (WaveHs, suunta, periodi,
 * veden lämpötila) ja WAM-aaltomallin pisteennuste. Poijuennusteesta +
 * spotin avoimuussuunnista appi johtaa surffi-ikkunan.
 */
import { type RawElement, parseElements } from "./fmi.js";

export interface WaveBuoyObservation {
  time: string;
  latitude: number;
  longitude: number;
  /** Merkitsevä aallonkorkeus (m). */
  waveHeight: number | null;
  /** Aaltojen tulosuunta (°). */
  waveDirection: number | null;
  /** Huippuperiodi (s). */
  wavePeriod: number | null;
  /** Veden lämpötila (°C). */
  waterTemp: number | null;
}

export interface WaveForecastHour {
  time: string;
  height: number;
  direction: number | null;
  period: number | null;
}

export function buildWaveObservationUrl(lat: number, lon: number, now: () => Date = () => new Date()): string {
  const start = new Date(now().getTime() - 3 * 60 * 60 * 1000);
  const url = new URL("https://opendata.fmi.fi/wfs");
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", "2.0.0");
  url.searchParams.set("request", "getFeature");
  url.searchParams.set("storedquery_id", "fmi::observations::wave::simple");
  url.searchParams.set("latlon", `${lat.toFixed(4)},${lon.toFixed(4)}`);
  url.searchParams.set("maxlocations", "1");
  url.searchParams.set("parameters", "WaveHs,ModalWDi,WTP,TWATER");
  url.searchParams.set("starttime", start.toISOString());
  return url.toString();
}

export function buildWaveForecastUrl(lat: number, lon: number, now: () => Date = () => new Date()): string {
  const end = new Date(now().getTime() + 48 * 60 * 60 * 1000);
  const url = new URL("https://opendata.fmi.fi/wfs");
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", "2.0.0");
  url.searchParams.set("request", "getFeature");
  url.searchParams.set("storedquery_id", "fmi::forecast::wam::point::simple");
  url.searchParams.set("latlon", `${lat.toFixed(4)},${lon.toFixed(4)}`);
  url.searchParams.set("endtime", end.toISOString());
  return url.toString();
}

/** Tuorein täysi poijuhavainto (WaveHs samalta aikaleimalta). */
export function parseWaveObservation(xml: string): WaveBuoyObservation | null {
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
    const height = find("WaveHs");
    if (height === null) continue;
    return {
      time: times[i]!,
      latitude: list[0]!.lat,
      longitude: list[0]!.lon,
      waveHeight: height,
      waveDirection: find("ModalWDi"),
      wavePeriod: find("WTP"),
      waterTemp: find("TWATER"),
    };
  }
  return null;
}

/** WAM-ennuste tunneittain (SigWaveHeight/WaveDirection/WavePeriod). */
export function parseWaveForecast(xml: string): WaveForecastHour[] {
  const elements = parseElements(xml);
  const byTime = new Map<string, RawElement[]>();
  for (const element of elements) {
    const list = byTime.get(element.time) ?? [];
    list.push(element);
    byTime.set(element.time, list);
  }
  const hours: WaveForecastHour[] = [];
  for (const time of [...byTime.keys()].sort()) {
    const list = byTime.get(time)!;
    const find = (name: string) => list.find((e) => e.name === name)?.value ?? null;
    const height = find("SigWaveHeight");
    if (height === null) continue;
    hours.push({ time, height, direction: find("WaveDirection"), period: find("WavePeriod") });
  }
  return hours;
}

export interface FetchTextLike {
  (url: string): Promise<{ ok: boolean; status: number; text(): Promise<string> }>;
}

/** Hakee poijuhavainnon ja WAM-ennusteen; toisen virhe ei kaada toista. */
export async function fetchWaveData(
  lat: number,
  lon: number,
  fetchImpl: FetchTextLike = fetch,
  now: () => Date = () => new Date(),
): Promise<{ buoy: WaveBuoyObservation | null; forecast: WaveForecastHour[] }> {
  const [buoy, forecast] = await Promise.allSettled([
    fetchImpl(buildWaveObservationUrl(lat, lon, now)).then(async (res) =>
      res.ok ? parseWaveObservation(await res.text()) : null,
    ),
    fetchImpl(buildWaveForecastUrl(lat, lon, now)).then(async (res) =>
      res.ok ? parseWaveForecast(await res.text()) : [],
    ),
  ]);
  return {
    buoy: buoy.status === "fulfilled" ? buoy.value : null,
    forecast: forecast.status === "fulfilled" ? forecast.value : [],
  };
}

// --- Merisää kartalle: kaikki poijut ja tuuliasemat alueella ---

export interface SeaStateStation {
  latitude: number;
  longitude: number;
  time: string;
  /** Poiju: aallonkorkeus (m). */
  waveHeight?: number;
  waveDirection?: number;
  wavePeriod?: number;
  waterTemp?: number;
  /** Sääasema: tuuli (m/s). */
  windSpeed?: number;
  windGust?: number;
  windDirection?: number;
}

function buildBboxUrl(storedQuery: string, parameters: string, bbox: string, hoursBack: number, now: () => Date): string {
  const start = new Date(now().getTime() - hoursBack * 3600 * 1000);
  const url = new URL("https://opendata.fmi.fi/wfs");
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", "2.0.0");
  url.searchParams.set("request", "getFeature");
  url.searchParams.set("storedquery_id", storedQuery);
  url.searchParams.set("bbox", bbox);
  url.searchParams.set("parameters", parameters);
  url.searchParams.set("starttime", start.toISOString());
  return url.toString();
}

/** Ryhmittelee BsWfs-elementit asemittain ja poimii tuoreimman täyden setin. */
export function parseStations(xml: string, requireName: string): SeaStateStation[] {
  const elements = parseElements(xml);
  const byStation = new Map<string, RawElement[]>();
  for (const element of elements) {
    const key = `${element.lat.toFixed(3)},${element.lon.toFixed(3)}`;
    const list = byStation.get(key) ?? [];
    list.push(element);
    byStation.set(key, list);
  }
  const stations: SeaStateStation[] = [];
  for (const list of byStation.values()) {
    const byTime = new Map<string, RawElement[]>();
    for (const element of list) {
      const timeList = byTime.get(element.time) ?? [];
      timeList.push(element);
      byTime.set(element.time, timeList);
    }
    const times = [...byTime.keys()].sort();
    for (let i = times.length - 1; i >= 0; i--) {
      const timeList = byTime.get(times[i]!)!;
      const find = (name: string) => timeList.find((e) => e.name === name)?.value;
      if (find(requireName) === undefined) continue;
      stations.push({
        latitude: timeList[0]!.lat,
        longitude: timeList[0]!.lon,
        time: times[i]!,
        waveHeight: find("WaveHs"),
        waveDirection: find("ModalWDi"),
        wavePeriod: find("WTP"),
        waterTemp: find("TWATER"),
        windSpeed: find("ws_10min"),
        windGust: find("wg_10min"),
        windDirection: find("wd_10min"),
      });
      break;
    }
  }
  return stations;
}

/** Merisää alueelle: aaltopoijut + tuuliasemat (bbox = minLon,minLat,maxLon,maxLat). */
export async function fetchSeaState(
  bbox: string,
  fetchImpl: FetchTextLike = fetch,
  now: () => Date = () => new Date(),
): Promise<{ buoys: SeaStateStation[]; stations: SeaStateStation[] }> {
  const [buoys, stations] = await Promise.allSettled([
    fetchImpl(buildBboxUrl("fmi::observations::wave::simple", "WaveHs,ModalWDi,WTP,TWATER", bbox, 3, now))
      .then(async (res) => (res.ok ? parseStations(await res.text(), "WaveHs") : [])),
    fetchImpl(buildBboxUrl("fmi::observations::weather::simple", "ws_10min,wg_10min,wd_10min", bbox, 1, now))
      .then(async (res) => (res.ok ? parseStations(await res.text(), "ws_10min") : [])),
  ]);
  return {
    buoys: buoys.status === "fulfilled" ? buoys.value : [],
    stations: stations.status === "fulfilled" ? stations.value : [],
  };
}
