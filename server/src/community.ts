/**
 * Yhteisödata tietokannassa: julkiset spotit versiohistorialla ja kommentit.
 * Reitit (app.ts) hoitavat tokenit ja omistajuuden; tämä kerros vain datan.
 */
import { and, asc, count, desc, eq, isNull } from "drizzle-orm";
import type { Db } from "./db/index.js";
import { publicSpots, spotComments, spotRevisions } from "./db/schema.js";
import type { PublicSpot, SpotComment } from "./public.js";
import type { JsonStore } from "./store.js";

type SpotRow = typeof publicSpots.$inferSelect;

function toSpot(row: SpotRow): PublicSpot {
  return {
    id: row.id,
    name: row.name,
    latitude: row.latitude,
    longitude: row.longitude,
    waterType: row.waterType === "sea" ? "sea" : "lake",
    sports: row.sports ?? [],
    goodDirections: row.goodDirections ?? undefined,
    minWind: row.minWind ?? undefined,
    maxWind: row.maxWind ?? undefined,
    ownerHash: row.ownerHash,
    ownerUserId: row.ownerUserId ?? undefined,
    updatedAt: row.updatedAt.toISOString(),
  };
}

export async function listSpots(db: Db): Promise<{ spot: PublicSpot; commentCount: number }[]> {
  const rows = await db.select().from(publicSpots).where(isNull(publicSpots.deletedAt)).orderBy(asc(publicSpots.name));
  const counts = await db
    .select({ spotId: spotComments.spotId, n: count() })
    .from(spotComments)
    .where(isNull(spotComments.deletedAt))
    .groupBy(spotComments.spotId);
  const bySpot = new Map(counts.map((c) => [c.spotId, Number(c.n)]));
  return rows.map((row) => ({ spot: toSpot(row), commentCount: bySpot.get(row.id) ?? 0 }));
}

export async function getSpot(db: Db, id: string): Promise<PublicSpot | null> {
  const rows = await db.select().from(publicSpots)
    .where(and(eq(publicSpots.id, id), isNull(publicSpots.deletedAt))).limit(1);
  return rows[0] ? toSpot(rows[0]) : null;
}

export async function countSpots(db: Db): Promise<number> {
  const rows = await db.select({ n: count() }).from(publicSpots).where(isNull(publicSpots.deletedAt));
  return Number(rows[0]?.n ?? 0);
}

/** Luo tai päivittää spotin ja kirjaa version. Omistajatarkistus on kutsujan. */
export async function saveSpot(db: Db, spot: PublicSpot, editorHash: string, editorUserId: string | null = null): Promise<void> {
  const updatedAt = new Date(spot.updatedAt);
  const values = {
    id: spot.id,
    name: spot.name,
    latitude: spot.latitude,
    longitude: spot.longitude,
    waterType: spot.waterType,
    sports: spot.sports,
    goodDirections: spot.goodDirections ?? null,
    minWind: spot.minWind ?? null,
    maxWind: spot.maxWind ?? null,
    ownerHash: spot.ownerHash,
    ownerUserId: spot.ownerUserId ?? null,
    updatedAt,
    deletedAt: null,
  };
  await db.transaction(async (tx) => {
    await tx.insert(publicSpots).values(values).onConflictDoUpdate({
      target: publicSpots.id,
      set: { ...values, ownerHash: undefined, id: undefined },
    });
    const { ownerHash, ownerUserId, ...data } = spot;
    await tx.insert(spotRevisions).values({ spotId: spot.id, editorHash, editorUserId, data, createdAt: updatedAt });
  });
}

/** Pehmeä poisto: historia säilyy, palautus mahdollinen täydellä tokenilla. */
export async function deleteSpot(db: Db, id: string, now: Date): Promise<void> {
  await db.update(publicSpots).set({ deletedAt: now }).where(eq(publicSpots.id, id));
}

export async function listRevisions(db: Db, spotId: string) {
  return db.select().from(spotRevisions).where(eq(spotRevisions.spotId, spotId)).orderBy(desc(spotRevisions.createdAt));
}

export async function listComments(db: Db, spotId: string, limit = 200): Promise<SpotComment[]> {
  const rows = await db.select().from(spotComments)
    .where(and(eq(spotComments.spotId, spotId), isNull(spotComments.deletedAt)))
    .orderBy(desc(spotComments.createdAt)).limit(limit);
  return rows.map((r) => ({
    id: r.id,
    spotId: r.spotId,
    author: r.author,
    text: r.text,
    windMs: r.windMs ?? undefined,
    windDir: r.windDir ?? undefined,
    createdAt: r.createdAt.toISOString(),
  }));
}

export async function countComments(db: Db, spotId: string): Promise<number> {
  const rows = await db.select({ n: count() }).from(spotComments)
    .where(and(eq(spotComments.spotId, spotId), isNull(spotComments.deletedAt)));
  return Number(rows[0]?.n ?? 0);
}

export async function addComment(db: Db, comment: SpotComment, userId: string | null = null): Promise<void> {
  await db.insert(spotComments).values({
    id: comment.id,
    spotId: comment.spotId,
    author: comment.author,
    userId,
    text: comment.text,
    windMs: comment.windMs ?? null,
    windDir: comment.windDir ?? null,
    createdAt: new Date(comment.createdAt),
  }).onConflictDoNothing();
}

/**
 * Kertasiirto vanhoista JSON-tiedostoista. Ajetaan käynnistyksessä; tiedostot
 * poistetaan vasta kun kaikki on kannassa.
 */
export async function migrateCommunityJson(db: Db, store: JsonStore): Promise<void> {
  const spots = await store.read<PublicSpot[] | null>("public-spots", null);
  const comments = await store.read<SpotComment[] | null>("spot-comments", null);
  if (!spots && !comments) return;
  for (const spot of spots ?? []) {
    if (!spot?.id) continue;
    await saveSpot(db, { ...spot, updatedAt: spot.updatedAt ?? new Date().toISOString() }, spot.ownerHash ?? "");
  }
  for (const comment of comments ?? []) {
    if (comment?.id && comment.spotId) await addComment(db, comment);
  }
  await store.remove("public-spots");
  await store.remove("spot-comments");
}
