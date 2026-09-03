/**
 * Tilin synkka: käyttäjän omat spotit ja kelivahtihälytykset palvelimella tilin
 * alla — varmuuskopio ja kelivahdin lähtödata. Puhelin on totuus, palvelin kopio.
 * Sessiot (GPS, syke) eivät kulje tätä kautta: ne pysyvät puhelimessa.
 */
import { eq } from "drizzle-orm";
import type { Db } from "./db/index.js";
import { userAlerts, userSpots } from "./db/schema.js";

export async function listUserSpots(db: Db, userId: string): Promise<Record<string, unknown>[]> {
  const rows = await db.select().from(userSpots).where(eq(userSpots.userId, userId));
  return rows.map((r) => r.data);
}

/** Korvaa käyttäjän spottilistan (puhelimen lista on totuus). */
export async function replaceUserSpots(db: Db, userId: string, spots: Record<string, unknown>[], now: Date): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.delete(userSpots).where(eq(userSpots.userId, userId));
    if (spots.length) {
      await tx.insert(userSpots).values(spots.map((data) => ({ userId, spotId: String(data.id), data, updatedAt: now })));
    }
  });
}

export async function listUserAlerts(db: Db, userId: string): Promise<Record<string, unknown>[]> {
  const rows = await db.select().from(userAlerts).where(eq(userAlerts.userId, userId));
  return rows.map((r) => r.data);
}

export async function replaceUserAlerts(db: Db, userId: string, alerts: Record<string, unknown>[], now: Date): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.delete(userAlerts).where(eq(userAlerts.userId, userId));
    if (alerts.length) {
      await tx.insert(userAlerts).values(alerts.map((data) => ({ userId, alertId: String(data.id), data, updatedAt: now })));
    }
  });
}

/** Kaikkien käyttäjien hälytykset kelivahdin kierrokselle. */
export async function allUserAlerts(db: Db): Promise<{ userId: string; data: Record<string, unknown> }[]> {
  const rows = await db.select().from(userAlerts);
  return rows.map((r) => ({ userId: r.userId, data: r.data }));
}
