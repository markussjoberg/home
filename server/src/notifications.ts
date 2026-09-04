/**
 * Appin sisäiset ilmoitukset kirjautuneille: kun omaan tai osallistuttuun
 * spottiin tapahtuu jotain (poistoehdotus, uusi kommentti). Push-kanavaa ei
 * ole, joten appi hakee nämä tilin kautta.
 */
import { and, desc, eq, inArray, isNull } from "drizzle-orm";
import type { Db } from "./db/index.js";
import { notifications, spotComments, spotRevisions, userDevices } from "./db/schema.js";
import { and as andAlso, eq as eqAlso } from "drizzle-orm";
import type { PublicSpot } from "./public.js";
import { type PushSender, pushToUser } from "./push.js";

/** Push-lähettäjä (null = pois päältä); asetetaan createAppissa. */
let pushSender: PushSender | null = null;
export function setPushSender(sender: PushSender | null): void { pushSender = sender; }

const KIND_TITLES: Record<string, string> = {
  kelivahti: "Kelivahti", comment: "Uusi kommentti", deletion_proposed: "Poistoehdotus", deletion_executed: "Spotti poistettu",
};

async function pushAlso(db: Db, userIds: string[], kind: string, spotName: string, message: string, spotId: string): Promise<void> {
  if (!pushSender) return;
  for (const userId of userIds) {
    await pushToUser(db, pushSender, userId, {
      title: `${KIND_TITLES[kind] ?? "Noste"} · ${spotName}`, body: message, data: { kind, spotId },
    }).catch(() => undefined);
  }
}

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
  await pushAlso(db, rows.map((r) => r.userId), input.kind, input.spot.name, input.message, input.spot.id);
  return rows.length;
}

/** Yksittäinen ilmoitus dedup-avaimella: sama avain samalle käyttäjälle vain kerran. */
export async function notifyOnce(db: Db, userId: string, input: {
  kind: string; spotId: string; spotName: string; message: string; dedupKey: string; now: Date;
}): Promise<boolean> {
  const existing = await db.select({ id: notifications.id }).from(notifications)
    .where(andAlso(eqAlso(notifications.userId, userId), eqAlso(notifications.dedupKey, input.dedupKey))).limit(1);
  if (existing.length) return false;
  await db.insert(notifications).values({
    userId, kind: input.kind, spotId: input.spotId, spotName: input.spotName, message: input.message,
    dedupKey: input.dedupKey, createdAt: input.now,
  });
  await pushAlso(db, [userId], input.kind, input.spotName, input.message, input.spotId);
  return true;
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
