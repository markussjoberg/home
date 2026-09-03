/**
 * Tunnukset: Sign in with Apple + nimimerkki. Apple antaa appille identity
 * tokenin (JWT), jonka allekirjoitus tarkistetaan Applen julkisilla avaimilla;
 * palvelin antaa oman istuntotunnisteen. Salasanoja ei ole eikä tule.
 * Laiteavaimen hash sidotaan tunnukseen, jolloin ennen kirjautumista tehdyt
 * spotit ja kommentit seuraavat käyttäjää laitteelta toiselle.
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, isNull, sql } from "drizzle-orm";
import { createRemoteJWKSet, jwtVerify } from "jose";
import type { Db } from "./db/index.js";
import { publicSpots, userDevices, userTokens, users } from "./db/schema.js";

export interface Identity {
  sub: string;
  email?: string;
}

export type IdentityVerifier = (identityToken: string) => Promise<Identity>;

/** Applen identity tokenin tarkistus: allekirjoitus, myöntäjä, yleisö (bundle id). */
export function appleIdentityVerifier(audiences: string[]): IdentityVerifier {
  const jwks = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
  return async (identityToken) => {
    const { payload } = await jwtVerify(identityToken, jwks, {
      issuer: "https://appleid.apple.com",
      audience: audiences,
    });
    if (typeof payload.sub !== "string" || !payload.sub) throw new Error("sub puuttuu");
    return { sub: payload.sub, email: typeof payload.email === "string" ? payload.email : undefined };
  };
}

export interface User {
  id: string;
  nickname: string | null;
  email: string | null;
  role: string;
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** Nimimerkki: 3–24 merkkiä, kirjaimia, numeroita, väliviiva, alaviiva. */
export function normalizeNickname(raw: unknown): string | null {
  const value = String(raw ?? "").trim();
  if (!/^[\p{L}\p{N}_-]{3,24}$/u.test(value)) return null;
  return value;
}

export async function nicknameTaken(db: Db, nickname: string, exceptUserId?: string): Promise<boolean> {
  const rows = await db.select({ id: users.id }).from(users)
    .where(sql`lower(${users.nickname}) = lower(${nickname})`).limit(1);
  return rows.some((r) => r.id !== exceptUserId);
}

/** Kirjautuminen: luo käyttäjän tarvittaessa, sitoo laiteavaimen ja antaa istuntotunnisteen. */
export async function signIn(db: Db, identity: Identity, ownerHash: string | null, now: Date)
  : Promise<{ user: User; token: string }> {
  let row = (await db.select().from(users).where(eq(users.appleSub, identity.sub)).limit(1))[0];
  if (!row) {
    await db.insert(users).values({
      id: randomUUID(), appleSub: identity.sub, email: identity.email ?? null, createdAt: now, lastSeenAt: now,
    }).onConflictDoNothing();
    row = (await db.select().from(users).where(eq(users.appleSub, identity.sub)).limit(1))[0]!;
  } else {
    await db.update(users).set({ lastSeenAt: now, email: identity.email ?? row.email }).where(eq(users.id, row.id));
  }
  if (ownerHash) await linkDevice(db, row.id, ownerHash, now);
  const token = randomBytes(32).toString("hex");
  await db.insert(userTokens).values({ tokenHash: hashToken(token), userId: row.id, createdAt: now, lastUsedAt: now });
  return { user: toUser(row), token };
}

/** Sitoo laiteavaimen käyttäjään ja siirtää sillä julkaistut spotit tunnukselle. */
export async function linkDevice(db: Db, userId: string, ownerHash: string, now: Date): Promise<void> {
  await db.insert(userDevices).values({ ownerHash, userId, linkedAt: now })
    .onConflictDoUpdate({ target: userDevices.ownerHash, set: { userId, linkedAt: now } });
  await db.update(publicSpots).set({ ownerUserId: userId })
    .where(and(eq(publicSpots.ownerHash, ownerHash), isNull(publicSpots.ownerUserId)));
}

export async function userForToken(db: Db, token: string | undefined, now: Date): Promise<User | null> {
  if (!token) return null;
  const tokenHash = hashToken(token);
  const rows = await db.select({ user: users, lastUsedAt: userTokens.lastUsedAt })
    .from(userTokens).innerJoin(users, eq(users.id, userTokens.userId))
    .where(eq(userTokens.tokenHash, tokenHash)).limit(1);
  const hit = rows[0];
  if (!hit) return null;
  if (now.getTime() - hit.lastUsedAt.getTime() > 3600_000) {
    await db.update(userTokens).set({ lastUsedAt: now }).where(eq(userTokens.tokenHash, tokenHash));
  }
  return toUser(hit.user);
}

export async function revokeToken(db: Db, token: string): Promise<void> {
  await db.delete(userTokens).where(eq(userTokens.tokenHash, hashToken(token)));
}

export async function setNickname(db: Db, userId: string, nickname: string): Promise<User | null> {
  await db.update(users).set({ nickname }).where(eq(users.id, userId));
  const row = (await db.select().from(users).where(eq(users.id, userId)).limit(1))[0];
  return row ? toUser(row) : null;
}

/**
 * Tilin poisto (App Store vaatii): tunniste, istunnot, laitesidonnat, omat
 * spotit ja hälytykset poistetaan; ilmoitukset poistetaan. Yhteisösisältö
 * (julkaistut spotit, kommentit, versiot) jää wikimäisesti mutta irrotetaan
 * tilistä — kommentin kirjoittajaksi jää nimimerkki, jota ei enää voi
 * yhdistää kenenkään tunnukseen.
 */
export async function deleteAccount(db: Db, userId: string): Promise<void> {
  const { notifications, publicSpots, spotComments, spotRevisions, userAlerts, userSpots } = await import("./db/schema.js");
  await db.transaction(async (tx) => {
    await tx.delete(userTokens).where(eq(userTokens.userId, userId));
    await tx.delete(userDevices).where(eq(userDevices.userId, userId));
    await tx.delete(userSpots).where(eq(userSpots.userId, userId));
    await tx.delete(userAlerts).where(eq(userAlerts.userId, userId));
    await tx.delete(notifications).where(eq(notifications.userId, userId));
    await tx.update(publicSpots).set({ ownerUserId: null }).where(eq(publicSpots.ownerUserId, userId));
    await tx.update(spotComments).set({ userId: null }).where(eq(spotComments.userId, userId));
    await tx.update(spotRevisions).set({ editorUserId: null }).where(eq(spotRevisions.editorUserId, userId));
    await tx.delete(users).where(eq(users.id, userId));
  });
}

export async function deviceHashes(db: Db, userId: string): Promise<string[]> {
  const rows = await db.select({ ownerHash: userDevices.ownerHash }).from(userDevices).where(eq(userDevices.userId, userId));
  return rows.map((r) => r.ownerHash);
}

function toUser(row: typeof users.$inferSelect): User {
  return { id: row.id, nickname: row.nickname, email: row.email, role: row.role };
}
