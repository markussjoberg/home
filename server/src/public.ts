/**
 * Julkiset spotit ja niiden kommentit ("millä keleillä toimii") — yhteinen
 * pooli kaikille käyttäjille. Kirjoitus onnistuu appiin upotetulla tokenilla;
 * omistajuus todistetaan laitekohtaisella avaimella (hash talteen), jolloin
 * vain lisääjä voi muokata/poistaa omansa. Kevyt pilottitoteutus — ei
 * käyttäjätilejä (vielä).
 */
import { createHash } from "node:crypto";

export interface PublicSpot {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  waterType: "sea" | "lake";
  sports: string[];
  goodDirections?: number[];
  minWind?: number;
  maxWind?: number;
  /** Yhteinen kuvaus — kuka tahansa kirjautunut voi täydentää (wiki). */
  description?: string;
  /** sha256(ownerKey) — ei koskaan ulos rajapinnasta. */
  ownerHash: string;
  /** Omistava käyttäjä (kirjautunut julkaisija). */
  ownerUserId?: string;
  updatedAt: string;
}

export interface SpotComment {
  id: string;
  spotId: string;
  author: string;
  text: string;
  /** Tuuli kommentin keleistä (m/s, aste) — vapaaehtoinen. */
  windMs?: number;
  windDir?: number;
  createdAt: string;
}

export const MAX_PUBLIC_SPOTS = 5000;
export const MAX_COMMENTS_PER_SPOT = 500;

export function hashOwnerKey(key: string): string {
  return createHash("sha256").update(key).digest("hex");
}

/** Siivoaa käyttäjän syöttämän tekstin: ohjausmerkit pois, pituusraja. */
export function cleanText(value: unknown, maxLength: number): string {
  return String(value ?? "")
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

/** Validoi ja normalisoi spotin; null jos kelvoton. */
export function parsePublicSpot(body: unknown, id: string, ownerHash: string, now: Date): PublicSpot | null {
  const b = (body ?? {}) as Record<string, unknown>;
  const name = cleanText(b.name, 60);
  const latitude = Number(b.latitude);
  const longitude = Number(b.longitude);
  if (!name || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  // Pohjola: Suomi, Skandinavia (Norjan rannikko ~4°E asti), Baltia.
  if (latitude < 54 || latitude > 72 || longitude < 3 || longitude > 32) return null;
  const sports = Array.isArray(b.sports)
    ? b.sports.map((s) => cleanText(s, 20)).filter(Boolean).slice(0, 8)
    : [];
  const directions = Array.isArray(b.goodDirections)
    ? b.goodDirections.map(Number).filter((d) => Number.isInteger(d) && d >= 0 && d <= 7).slice(0, 8)
    : undefined;
  const minWind = Number.isFinite(Number(b.minWind)) ? Number(b.minWind) : undefined;
  const description = cleanText(b.description, 600) || undefined;
  const maxWind = Number.isFinite(Number(b.maxWind)) ? Number(b.maxWind) : undefined;
  return {
    id,
    name,
    latitude,
    longitude,
    waterType: b.waterType === "sea" ? "sea" : "lake",
    sports,
    goodDirections: directions?.length ? directions : undefined,
    minWind,
    maxWind,
    description,
    ownerHash,
    updatedAt: now.toISOString(),
  };
}

/** Validoi kommentin; null jos kelvoton. */
export function parseComment(body: unknown, spotId: string, now: Date): SpotComment | null {
  const b = (body ?? {}) as Record<string, unknown>;
  const author = cleanText(b.author, 24);
  const text = cleanText(b.text, 500);
  if (!author || !text) return null;
  const windMs = Number(b.windMs);
  const windDir = Number(b.windDir);
  return {
    id: `${now.getTime()}-${hashOwnerKey(text + author).slice(0, 8)}`,
    spotId,
    author,
    text,
    windMs: Number.isFinite(windMs) && windMs >= 0 && windMs <= 60 ? Math.round(windMs * 10) / 10 : undefined,
    windDir: Number.isFinite(windDir) && windDir >= 0 && windDir < 360 ? Math.round(windDir) : undefined,
    createdAt: now.toISOString(),
  };
}

/** Julkinen muoto: omistajahash ei lähde ulos. */
export function toPublicJson(spot: PublicSpot, commentCount: number, mine = false) {
  const { ownerHash, ownerUserId, ...rest } = spot;
  return { ...rest, commentCount, mine };
}
