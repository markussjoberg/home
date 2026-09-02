/**
 * Appin sisäiset ilmoitukset kirjautuneille: kun omaan tai osallistuttuun
 * spottiin tapahtuu jotain (poistoehdotus, uusi kommentti). Push-kanavaa ei
 * ole, joten appi hakee nämä tilin kautta.
 */
import { and, desc, eq, inArray, isNull } from "drizzle-orm";
import type { Db } from "./db/index.js";
import { notifications, spotComments, spotRevisions, userDevices } from "./db/schema.js";
import type { PublicSpot } from "./public.js";

/** Käyttäjät, joita spotti koskee: omistaja, laitteen kautta omistavat, kommentoineet, muokanneet. */
export async function stakeholders(db: Db, spot: PublicSpot): Promise<Set<string>> {
  const ids = new Set<string>();
  if (spot.ownerUserId) ids.add(spot.ownerUserId);
  const devices = await db.select({ userId: userDevices.userId }).from(userDevices).where(eq(userDevices.ownerHash, spot.ownerHash));
  for (const d of devices) ids.add(d.userId);
  const comments = await db.select({ userId: spotComments.userId }).from(spotComments)
    .where(and(eq(spotComments.spotId, spot.id), isNull(spotComments.deletedAt)));
  for (const c of comments) if (c.userId) ids.add(c.userId);
  const revisions = await db.select({ userId: spotRevisions.editorUserId }).from(spotRevisions).where(eq(spotRevisions.spotId, spot.id));
  for (const r of revisions) if (r.userId) ids.add(r.userId);
  return ids;
}

export async function notify(db: Db, userIds: Iterable<string>, input: {
  kind: string; spot: PublicSpot; message: string; now: Date; exclude?: string | null;
}): Promise<number> {
  const rows = [...new Set(userIds)].filter((id) => id !== input.exclude).map((userId) => ({
    userId, kind: input.kind, spotId: input.spot.id, spotName: input.spot.name, message: input.message, createdAt: input.now,
  }));
  if (!rows.length) return 0;
  await db.insert(notifications).values(rows);
  return rows.length;
}

export async function listNotifications(db: Db, userId: string, limit = 50) {
  const rows = await db.select().from(notifications).where(eq(notifications.userId, userId))
    .orderBy(desc(notifications.createdAt)).limit(limit);
  return rows.map((r) => ({
    id: r.id, kind: r.kind, spotId: r.spotId, spotName: r.spotName, message: r.message,
    createdAt: r.createdAt.toISOString(), read: r.readAt !== null,
  }));
}

export async function markRead(db: Db, userId: string, ids: number[] | "all", now: Date): Promise<void> {
  const base = and(eq(notifications.userId, userId), isNull(notifications.readAt));
  if (ids === "all") {
    await db.update(notifications).set({ readAt: now }).where(base);
  } else if (ids.length) {
    await db.update(notifications).set({ readAt: now }).where(and(base, inArray(notifications.id, ids)));
  }
}
