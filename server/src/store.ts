/**
 * Yksinkertainen JSON-tiedostovarasto (yksi käyttäjä, oma palvelin — ei tietokantaa
 * ennen kuin tarve osoittaa toista). Kirjoitus atomisesti väliaikaistiedoston kautta.
 * Saman nimen luku-muokkaus-kirjoitukset sarjoitetaan (update), muuten kaksi
 * samanaikaista yhteisökirjoitusta hävittäisi toisen.
 */
import { mkdir, readFile, readdir, rename, unlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export class JsonStore {
  private locks = new Map<string, Promise<unknown>>();

  constructor(private readonly dataDir: string) {}

  private path(name: string): string {
    return join(this.dataDir, `${name}.json`);
  }

  async read<T>(name: string, fallback: T): Promise<T> {
    try {
      return JSON.parse(await readFile(this.path(name), "utf8")) as T;
    } catch {
      return fallback;
    }
  }

  async write(name: string, value: unknown): Promise<void> {
    const target = this.path(name);
    await mkdir(dirname(target), { recursive: true });
    // Uniikki väliaikaisnimi: kaksi rinnakkaista kirjoitusta ei törmää samaan .tmp:hen.
    const temp = `${target}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
    await writeFile(temp, JSON.stringify(value, null, 2), "utf8");
    await rename(temp, target);
  }

  /** Sarjoitettu luku-muokkaus-kirjoitus: fn saa nykyisen arvon ja palauttaa uuden. */
  async update<T>(name: string, fallback: T, fn: (current: T) => T | Promise<T>): Promise<T> {
    const previous = this.locks.get(name) ?? Promise.resolve();
    const run = previous
      .catch(() => undefined)
      .then(async () => {
        const next = await fn(await this.read<T>(name, fallback));
        await this.write(name, next);
        return next;
      });
    this.locks.set(name, run);
    run.finally(() => {
      if (this.locks.get(name) === run) this.locks.delete(name);
    }).catch(() => undefined);
    return run;
  }

  /** Lisää listaan alkiot, korvaten samalla id:llä olevat. */
  async upsertById<T extends { id: string }>(name: string, items: T[]): Promise<T[]> {
    return this.update<T[]>(name, [], (existing) => {
      const byId = new Map(existing.map((item) => [item.id, item]));
      for (const item of items) byId.set(item.id, item);
      return [...byId.values()];
    });
  }

  /** Hakemiston tiedostojen nimet (ilman .json) — esim. sessiot yksi per tiedosto. */
  async list(dir: string): Promise<string[]> {
    try {
      return (await readdir(join(this.dataDir, dir)))
        .filter((f) => f.endsWith(".json") && !f.includes(".tmp"))
        .map((f) => f.slice(0, -5));
    } catch {
      return [];
    }
  }

  async remove(name: string): Promise<void> {
    await unlink(this.path(name)).catch(() => undefined);
  }
}
