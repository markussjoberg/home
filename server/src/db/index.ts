/**
 * Tietokantayhteys. Tuotannossa Postgres (DATABASE_URL); ilman osoitetta
 * PGlite (Postgres WASM:na) levylle data-hakemistoon — kehitys ja pienet
 * asennukset toimivat ilman erillistä kantaa. Testit ajavat PGliten muistissa.
 * Sama skeema ja migraatiot kaikissa.
 */
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { PgDatabase, PgQueryResultHKT } from "drizzle-orm/pg-core";
import * as schema from "./schema.js";

export type Db = PgDatabase<PgQueryResultHKT, typeof schema>;

const migrationsFolder = fileURLToPath(new URL("../../drizzle", import.meta.url));

export interface DbHandle {
  db: Db;
  close(): Promise<void>;
}

export async function connectDatabase(databaseUrl: string, dataDir: string): Promise<DbHandle> {
  if (databaseUrl) {
    const { Pool } = await import("pg");
    const { drizzle } = await import("drizzle-orm/node-postgres");
    const { migrate } = await import("drizzle-orm/node-postgres/migrator");
    const pool = new Pool({ connectionString: databaseUrl });
    const db = drizzle({ client: pool, schema });
    await migrate(db, { migrationsFolder });
    return { db: db as unknown as Db, close: () => pool.end() };
  }
  return openPglite(join(dataDir, "pglite"));
}

/** Testeille: muistinvarainen kanta migraatioilla, tyhjä joka kutsulla. */
export async function createTestDb(): Promise<DbHandle> {
  return openPglite(undefined);
}

async function openPglite(dataPath: string | undefined): Promise<DbHandle> {
  const { PGlite } = await import("@electric-sql/pglite");
  const { drizzle } = await import("drizzle-orm/pglite");
  const { migrate } = await import("drizzle-orm/pglite/migrator");
  if (dataPath) await mkdir(dataPath, { recursive: true }); // PGlite ei luo hakemistopolkua itse
  const client = dataPath ? new PGlite(dataPath) : new PGlite();
  const db = drizzle({ client, schema });
  await migrate(db, { migrationsFolder });
  return { db: db as unknown as Db, close: () => client.close() };
}
