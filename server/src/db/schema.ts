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
  /** sha256(ownerKey) — ei koskaan ulos rajapinnasta. */
  ownerHash: text("owner_hash").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

/** Jokainen tallennus jättää version: kuka (hash), milloin, mitä sisältöä. */
export const spotRevisions = pgTable("spot_revisions", {
  id: serial("id").primaryKey(),
  spotId: text("spot_id").notNull(),
  editorHash: text("editor_hash").notNull(),
  data: jsonb("data").$type<Record<string, unknown>>().notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const spotComments = pgTable("spot_comments", {
  id: text("id").primaryKey(),
  spotId: text("spot_id").notNull(),
  author: text("author").notNull(),
  text: text("text").notNull(),
  windMs: doublePrecision("wind_ms"),
  windDir: integer("wind_dir"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});
