/**
 * Yhteisön pelisäännöt: poistoehdotukset hiljaisella suostumuksella, ilmoitukset
 * ja oman sisällön hallinta. Wikimäinen periaate: julkaistu spotti on yhteinen
 * heti kun muut ovat lisänneet siihen jotain — silloin luoja ei poista yksin.
 */
import { and, eq, isNull, lte, ne, or } from "drizzle-orm";
import type { Db } from "./db/index.js";
import { publicSpots, reports, spotComments, spotDeletionProposals, spotRevisions } from "./db/schema.js";
import type { PublicSpot } from "./public.js";

/** Odotusaika ennen kuin vastustamaton poisto toteutuu. */
export const DELETION_GRACE_MS = 7 * 24 * 3600 * 1000;

/** Onko spotissa muiden kuin omistajan sisältöä (kommentit tai muokkaukset). */
export async function hasOthersContent(db: Db, spot: PublicSpot): Promise<boolean> {
  const comments = await db.select({ userId: spotComments.userId }).from(spotComments)
    .where(and(eq(spotComments.spotId, spot.id), isNull(spotComments.deletedAt))).limit(200);
  // Anonyymi kommentti on aina jonkun muun (omistaja kommentoi tunnuksellaan).
  if (comments.some((c) => c.userId === null || c.userId !== spot.ownerUserId)) return true;
  const revisions = await db.select({ editorHash: spotRevisions.editorHash, editorUserId: spotRevisions.editorUserId })
    .from(spotRevisions).where(eq(spotRevisions.spotId, spot.id)).limit(500);
  return revisions.some((r) => r.editorHash !== spot.ownerHash && (r.editorUserId === null || r.editorUserId !== spot.ownerUserId));
}

export interface Proposal {
  id: number;
  spotId: string;
  createdAt: string;
  decidesAt: string;
  status: string;
}

function toProposal(row: typeof spotDeletionProposals.$inferSelect): Proposal {
  return { id: row.id, spotId: row.spotId, createdAt: row.createdAt.toISOString(), decidesAt: row.decidesAt.toISOString(), status: row.status };
}

export async function openProposal(db: Db, spotId: string): Promise<Proposal | null> {
  const rows = await db.select().from(spotDeletionProposals)
    .where(and(eq(spotDeletionProposals.spotId, spotId), eq(spotDeletionProposals.status, "open"))).limit(1);
  return rows[0] ? toProposal(rows[0]) : null;
}

export async function openProposals(db: Db): Promise<Map<string, Proposal>> {
  const rows = await db.select().from(spotDeletionProposals).where(eq(spotDeletionProposals.status, "open"));
  return new Map(rows.map((r) => [r.spotId, toProposal(r)]));
}

/** Luo poistoehdotuksen (tai palauttaa avoimen). */
export async function proposeDeletion(db: Db, spotId: string, proposerHash: string, proposerUserId: string | null, now: Date): Promise<Proposal> {
  const existing = await openProposal(db, spotId);
  if (existing) return existing;
  const rows = await db.insert(spotDeletionProposals).values({
    spotId, proposerHash, proposerUserId, createdAt: now, decidesAt: new Date(now.getTime() + DELETION_GRACE_MS), status: "open",
  }).returning();
  return toProposal(rows[0]!);
}

/** Onko käyttäjä/laite osallistunut spottiin (kommentti tai muokkaus) — saa vastustaa. */
export async function isContributor(db: Db, spotId: string, ownerHash: string | null, userId: string | null): Promise<boolean> {
  if (userId) {
    const c = await db.select({ id: spotComments.id }).from(spotComments)
      .where(and(eq(spotComments.spotId, spotId), eq(spotComments.userId, userId))).limit(1);
    if (c.length) return true;
  }
  const conditions = [];
  if (ownerHash) conditions.push(eq(spotRevisions.editorHash, ownerHash));
  if (userId) conditions.push(eq(spotRevisions.editorUserId, userId));
  if (!conditions.length) return false;
  const r = await db.select({ id: spotRevisions.id }).from(spotRevisions)
    .where(and(eq(spotRevisions.spotId, spotId), or(...conditions))).limit(1);
  return r.length > 0;
}

export async function objectDeletion(db: Db, spotId: string, by: string, now: Date): Promise<boolean> {
  const updated = await db.update(spotDeletionProposals)
    .set({ status: "objected", objectedBy: by, resolvedAt: now })
    .where(and(eq(spotDeletionProposals.spotId, spotId), eq(spotDeletionProposals.status, "open"))).returning();
  return updated.length > 0;
}

export async function cancelDeletion(db: Db, spotId: string, proposerHash: string | null, proposerUserId: string | null, now: Date): Promise<boolean> {
  const conditions = [];
  if (proposerHash) conditions.push(eq(spotDeletionProposals.proposerHash, proposerHash));
  if (proposerUserId) conditions.push(eq(spotDeletionProposals.proposerUserId, proposerUserId));
  if (!conditions.length) return false;
  const updated = await db.update(spotDeletionProposals)
    .set({ status: "cancelled", resolvedAt: now })
    .where(and(eq(spotDeletionProposals.spotId, spotId), eq(spotDeletionProposals.status, "open"), or(...conditions)))
    .returning();
  return updated.length > 0;
}

/** Toteuttaa vastustamattomat, määräajan ohittaneet poistot. Palauttaa poistettujen id:t. */
export async function executeDueDeletions(db: Db, now: Date): Promise<string[]> {
  const due = await db.select().from(spotDeletionProposals)
    .where(and(eq(spotDeletionProposals.status, "open"), lte(spotDeletionProposals.decidesAt, now)));
  const deleted: string[] = [];
  for (const proposal of due) {
    await db.transaction(async (tx) => {
      await tx.update(publicSpots).set({ deletedAt: now }).where(and(eq(publicSpots.id, proposal.spotId), isNull(publicSpots.deletedAt)));
      await tx.update(spotDeletionProposals).set({ status: "executed", resolvedAt: now }).where(eq(spotDeletionProposals.id, proposal.id));
    });
    deleted.push(proposal.spotId);
  }
  return deleted;
}

// --- Ilmoitukset ---

export async function fileReport(db: Db, input: {
  targetType: "spot" | "comment"; targetId: string; reporterHash: string; reporterUserId: string | null; reason: string; now: Date;
}): Promise<"created" | "duplicate"> {
  const existing = await db.select({ id: reports.id }).from(reports).where(and(
    eq(reports.targetType, input.targetType), eq(reports.targetId, input.targetId),
    eq(reports.reporterHash, input.reporterHash), isNull(reports.resolvedAt),
  )).limit(1);
  if (existing.length) return "duplicate";
  await db.insert(reports).values({
    targetType: input.targetType, targetId: input.targetId, reporterHash: input.reporterHash,
    reporterUserId: input.reporterUserId, reason: input.reason, createdAt: input.now,
  });
  return "created";
}

/** Avoimet ilmoitukset kohteen tiedoilla (spotin nimi / kommentin teksti), jotta admin näkee mitä käsittelee. */
export async function openReports(db: Db) {
  const rows = await db.select().from(reports).where(isNull(reports.resolvedAt));
  const result = [];
  for (const { reporterHash, ...rest } of rows) {
    let target: { spotId?: string; spotName?: string; text?: string; author?: string; deleted?: boolean } = {};
    if (rest.targetType === "spot") {
      const spot = (await db.select().from(publicSpots).where(eq(publicSpots.id, rest.targetId)).limit(1))[0];
      target = spot ? { spotId: spot.id, spotName: spot.name, deleted: spot.deletedAt !== null } : { deleted: true };
    } else {
      const comment = (await db.select().from(spotComments).where(eq(spotComments.id, rest.targetId)).limit(1))[0];
      target = comment ? { spotId: comment.spotId, text: comment.text, author: comment.author, deleted: comment.deletedAt !== null } : { deleted: true };
    }
    result.push({ ...rest, createdAt: rest.createdAt.toISOString(), resolvedAt: null, target });
  }
  return result;
}

export async function resolveReport(db: Db, id: number, resolution: string, now: Date): Promise<boolean> {
  const updated = await db.update(reports).set({ resolvedAt: now, resolution }).where(and(eq(reports.id, id), isNull(reports.resolvedAt))).returning();
  return updated.length > 0;
}

// --- Oma sisältö ---

/** Kommentin pehmeä poisto kirjoittajan (userId) tai adminin toimesta. */
export async function deleteComment(db: Db, commentId: string, userId: string | null, admin: boolean, now: Date): Promise<"ok" | "forbidden" | "missing"> {
  const rows = await db.select().from(spotComments).where(and(eq(spotComments.id, commentId), isNull(spotComments.deletedAt))).limit(1);
  const comment = rows[0];
  if (!comment) return "missing";
  if (!admin && (!userId || comment.userId !== userId)) return "forbidden";
  await db.update(spotComments).set({ deletedAt: now }).where(eq(spotComments.id, commentId));
  return "ok";
}

export async function commentsByUser(db: Db, userId: string) {
  const rows = await db.select().from(spotComments)
    .where(and(eq(spotComments.userId, userId), isNull(spotComments.deletedAt), ne(spotComments.userId, "")));
  return rows.map((r) => ({ id: r.id, spotId: r.spotId, text: r.text, createdAt: r.createdAt.toISOString() }));
}
