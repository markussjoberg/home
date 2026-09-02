/**
 * Postgres-skeema (Drizzle). Yhteisödata ensin: julkiset spotit versiohistorialla
 * ja kommentit. Poistot ovat pehmeitä (deleted_at) — wikimäinen kulttuuri tarvitsee
 * historian, ja moderaatio palautuksen.
 */
import { doublePrecision, integer, jsonb, pgTable, serial, text, timestamp } from "drizzle-orm/pg-core";

export const publicSpots = pgTable("public_spots", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  latitude: doublePrecision("latitude").notNull(),
  longitude: doublePrecision("longitude").notNull(),
  waterType: text("water_type").notNull(),
  sports: jsonb("sports").$type<string[]>().notNull().default([]),
  goodDirections: jsonb("good_directions").$type<number[]>(),
  minWind: doublePrecision("min_wind"),
  maxWind: doublePrecision("max_wind"),
  /** Yhteinen kuvaus (wiki): pysäköinti, karikot, launch, etiketti. */
  description: text("description"),
  /** exact | coarse — karkea sijainti (~1 km) salailua varten: ranta näkyy, launch ei. */
  precision: text("precision").notNull().default("exact"),
  /** sha256(ownerKey) — ei koskaan ulos rajapinnasta. */
  ownerHash: text("owner_hash").notNull(),
  /** Omistava käyttäjä, kun julkaisija on kirjautunut. */
  ownerUserId: text("owner_user_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

/** Jokainen tallennus jättää version: kuka (hash), milloin, mitä sisältöä. */
export const spotRevisions = pgTable("spot_revisions", {
  id: serial("id").primaryKey(),
  spotId: text("spot_id").notNull(),
  editorHash: text("editor_hash").notNull(),
  editorUserId: text("editor_user_id"),
  data: jsonb("data").$type<Record<string, unknown>>().notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const spotComments = pgTable("spot_comments", {
  id: text("id").primaryKey(),
  spotId: text("spot_id").notNull(),
  author: text("author").notNull(),
  userId: text("user_id"),
  text: text("text").notNull(),
  windMs: doublePrecision("wind_ms"),
  windDir: integer("wind_dir"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

// --- Tunnukset ---

/** Käyttäjä: Sign in with Apple -tunniste + nimimerkki. Salasanaa ei ole. */
export const users = pgTable("users", {
  id: text("id").primaryKey(),
  appleSub: text("apple_sub").notNull().unique(),
  /** Näkyvä nimimerkki; ainutkertainen kirjainkoosta riippumatta (tarkistus koodissa). */
  nickname: text("nickname"),
  email: text("email"),
  role: text("role").notNull().default("user"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  lastSeenAt: timestamp("last_seen_at", { withTimezone: true }).notNull().defaultNow(),
});

/** Laiteavaimen hash → käyttäjä: vanhat spotit ja kommentit seuraavat tunnusta. */
export const userDevices = pgTable("user_devices", {
  ownerHash: text("owner_hash").primaryKey(),
  userId: text("user_id").notNull(),
  linkedAt: timestamp("linked_at", { withTimezone: true }).notNull().defaultNow(),
});

/** Istuntotunnisteet (vain hash talletetaan). */
export const userTokens = pgTable("user_tokens", {
  tokenHash: text("token_hash").primaryKey(),
  userId: text("user_id").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  lastUsedAt: timestamp("last_used_at", { withTimezone: true }).notNull().defaultNow(),
});

// --- Yhteisön pelisäännöt ---

/**
 * Poistoehdotus spotille, jossa on muiden sisältöä: toteutuu määräajan jälkeen
 * ellei kukaan sisällön tekijä vastusta (hiljaisuus = suostumus).
 */
export const spotDeletionProposals = pgTable("spot_deletion_proposals", {
  id: serial("id").primaryKey(),
  spotId: text("spot_id").notNull(),
  proposerHash: text("proposer_hash").notNull(),
  proposerUserId: text("proposer_user_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  decidesAt: timestamp("decides_at", { withTimezone: true }).notNull(),
  /** open | objected | executed | cancelled */
  status: text("status").notNull().default("open"),
  objectedBy: text("objected_by"),
  resolvedAt: timestamp("resolved_at", { withTimezone: true }),
});

/** Ilmoitus asiattomasta sisällöstä; admin käsittelee täydellä tokenilla. */
export const reports = pgTable("reports", {
  id: serial("id").primaryKey(),
  /** spot | comment */
  targetType: text("target_type").notNull(),
  targetId: text("target_id").notNull(),
  reporterHash: text("reporter_hash").notNull(),
  reporterUserId: text("reporter_user_id"),
  reason: text("reason").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  resolvedAt: timestamp("resolved_at", { withTimezone: true }),
  resolution: text("resolution"),
});

/** Käyttäjän ilmoitukset appiin (ei pushia): poistoehdotus, uusi kommentti omaan spottiin. */
export const notifications = pgTable("notifications", {
  id: serial("id").primaryKey(),
  userId: text("user_id").notNull(),
  /** deletion_proposed | comment | deletion_executed */
  kind: text("kind").notNull(),
  spotId: text("spot_id").notNull(),
  spotName: text("spot_name").notNull(),
  message: text("message").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  readAt: timestamp("read_at", { withTimezone: true }),
});
