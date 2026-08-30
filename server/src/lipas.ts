/**
 * Lipas-peili: koko relevantti aineisto (uimarannat, uimapaikat, veneilyn
 * palvelupaikat, melontakeskukset — yhteensä ~3 300 kohdetta) haetaan kerran
 * ja talletetaan levylle. Kyselyt vastataan peilistä ilman verkkoa, ja peili
 * virkistetään taustalla viikoittain — Lipaksen katkot tai osoitteenmuutokset
 * eivät näy käyttäjälle.
 */
import type { FetchLike, Place } from "./places.js";
import { LIPAS_TYPE_NAMES, haversineMeters, nearestPerCategory, parseLipasItems } from "./places.js";
import { JsonStore } from "./store.js";

export interface LipasMirrorData {
  fetchedAt: string;
  places: Omit<Place, "distanceM" | "source">[];
}

export const LIPAS_MIRROR_STORE = "lipas-mirror";
const PAGE_SIZE = 100;
const MAX_PAGES_PER_TYPE = 40;
export const MIRROR_MAX_AGE_DAYS = 7;

/** Peilisivun osoite: yksi tyyppikoodi, sivutus, vain tarvitut kentät. */
export function mirrorPageUrl(base: string, typeCode: number, page: number): string {
  const url = new URL(`${base.replace(/\/$/, "")}/sports-places`);
  url.searchParams.set("typeCodes", String(typeCode));
  url.searchParams.set("page", String(page));
  url.searchParams.set("pageSize", String(PAGE_SIZE));
  for (const field of ["name", "type.typeCode", "location.coordinates.wgs84"]) {
    url.searchParams.append("fields", field);
  }
  return url.toString();
}

/** Hakee koko aineiston sivu kerrallaan. Heittää, jos mitään ei saatu. */
export async function syncLipasMirror(
  base: string,
  fetchImpl: FetchLike = fetch,
  now: () => Date = () => new Date(),
): Promise<LipasMirrorData> {
  const places: LipasMirrorData["places"] = [];
  for (const code of Object.keys(LIPAS_TYPE_NAMES).map(Number)) {
    for (let page = 1; page <= MAX_PAGES_PER_TYPE; page++) {
      const res = await fetchImpl(mirrorPageUrl(base, code, page));
      if (!res.ok) break;
      const items = parseLipasItems(await res.json());
      places.push(...items);
      if (items.length < PAGE_SIZE) break;
    }
  }
  if (places.length === 0) {
    throw new Error("Lipas-peilin synkka ei tuottanut yhtään kohdetta");
  }
  return { fetchedAt: now().toISOString(), places };
}

export function mirrorIsStale(data: LipasMirrorData | null, now: Date, maxAgeDays = MIRROR_MAX_AGE_DAYS): boolean {
  if (!data || data.places.length === 0) return true;
  const age = now.getTime() - new Date(data.fetchedAt).getTime();
  return !Number.isFinite(age) || age > maxAgeDays * 24 * 3600 * 1000;
}

/** Kohteet säteellä peilistä, etäisyyksineen. */
export function lipasNearby(data: LipasMirrorData, lat: number, lon: number, maxDistanceM = 3000): Place[] {
  return data.places
    .map((place) => ({
      ...place,
      distanceM: Math.round(haversineMeters(lat, lon, place.latitude, place.longitude)),
      source: "lipas" as const,
    }))
    .filter((place) => place.distanceM <= maxDistanceM)
    .sort((a, b) => a.distanceM - b.distanceM);
}

/** Peilin elinkaari: levyltä muistiin, taustavirkistys, fallback liveen. */
export class LipasMirror {
  private data: LipasMirrorData | null = null;
  private loaded = false;
  private syncing: Promise<void> | null = null;

  constructor(
    private readonly store: JsonStore,
    private readonly base: string,
    private readonly fetchImpl: FetchLike,
    private readonly now: () => Date,
  ) {}

  /** Palauttaa peilin (tuore tai vanhentunut) ja käynnistää virkistyksen
   *  taustalle tarvittaessa. null vain, jos peiliä ei ole koskaan saatu. */
  async current(): Promise<LipasMirrorData | null> {
    if (!this.loaded) {
      this.data = await this.store.read<LipasMirrorData | null>(LIPAS_MIRROR_STORE, null);
      this.loaded = true;
    }
    if (mirrorIsStale(this.data, this.now()) && !this.syncing) {
      this.syncing = syncLipasMirror(this.base, this.fetchImpl, this.now)
        .then(async (fresh) => {
          this.data = fresh;
          await this.store.write(LIPAS_MIRROR_STORE, fresh);
        })
        .catch(() => { /* vanha peili (tai live-fallback) jää käyttöön */ })
        .finally(() => { this.syncing = null; });
      // Ensimmäisellä kerralla (ei peiliä lainkaan) odotetaan synkka loppuun.
      if (!this.data) await this.syncing;
    }
    return this.data;
  }
}

export { nearestPerCategory };
