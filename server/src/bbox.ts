/**
 * bbox-kyselyparametrin jäsennys kartan aluekyselyihin (merisää, tuuli- ja
 * aaltohila). Yhteinen tarkistus: järjestys, koordinaattirajat ja koko —
 * muuten mikä tahansa alue menisi FMI:lle/Open-Meteolle sellaisenaan.
 */
export type BBox = [minLon: number, minLat: number, maxLon: number, maxLat: number];

export const MAX_BBOX_SPAN = 20;

export function parseBBox(raw: string | undefined): { bbox: BBox } | { error: string } {
  const parts = (raw ?? "").split(",").map(Number);
  if (parts.length !== 4 || parts.some((v) => !Number.isFinite(v))) {
    return { error: "bbox=minLon,minLat,maxLon,maxLat vaaditaan" };
  }
  const [minLon, minLat, maxLon, maxLat] = parts as BBox;
  if (minLon >= maxLon || minLat >= maxLat) return { error: "bbox: min pitää olla pienempi kuin max" };
  if (minLat < -90 || maxLat > 90 || minLon < -180 || maxLon > 180) return { error: "bbox: koordinaatit rajojen ulkopuolella" };
  if (maxLon - minLon > MAX_BBOX_SPAN || maxLat - minLat > MAX_BBOX_SPAN) {
    return { error: `bbox: alue saa olla enintään ${MAX_BBOX_SPAN}° sivultaan` };
  }
  return { bbox: [minLon, minLat, maxLon, maxLat] };
}

/** Pyöristää 0,1°:een — välimuistiavain ja haku samasta alueesta. */
export function roundBBox(bbox: BBox): BBox {
  return bbox.map((v) => Math.round(v * 10) / 10) as BBox;
}
