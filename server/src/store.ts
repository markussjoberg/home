/**
 * Yksinkertainen JSON-tiedostovarasto (yksi käyttäjä, oma palvelin — ei tietokantaa
 * ennen kuin tarve osoittaa toista). Kirjoitus atomisesti väliaikaistiedoston kautta.
 */
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export class JsonStore {
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
    const temp = `${target}.tmp`;
    await writeFile(temp, JSON.stringify(value, null, 2), "utf8");
    await rename(temp, target);
  }

  /** Lisää listaan alkiot, korvaten samalla id:llä olevat. */
  async upsertById<T extends { id: string }>(name: string, items: T[]): Promise<T[]> {
    const existing = await this.read<T[]>(name, []);
    const byId = new Map(existing.map((item) => [item.id, item]));
    for (const item of items) byId.set(item.id, item);
    const merged = [...byId.values()];
    await this.write(name, merged);
    return merged;
  }
}
