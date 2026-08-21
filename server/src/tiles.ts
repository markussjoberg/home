/**
 * Karttatiilien proxy: MML-maastokartta (API-avain palvelimella, ei apissa) ja
 * merikartta. Tiilet välimuistitetaan levylle — ne muuttuvat harvoin ja sama
 * alue haetaan yhä uudelleen.
 */
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export function terrainTileUrl(z: number, x: number, y: number, apiKey: string): string {
  return (
    "https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0/maastokartta/default/" +
    `WGS84_Pseudo-Mercator/${z}/${y}/${x}.png?api-key=${encodeURIComponent(apiKey)}`
  );
}

export function marineTileUrl(template: string, z: number, x: number, y: number): string {
  return template
    .replaceAll("{z}", String(z))
    .replaceAll("{y}", String(y))
    .replaceAll("{x}", String(x));
}

export function validTile(z: number, x: number, y: number): boolean {
  if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) return false;
  if (z < 0 || z > 19) return false;
  const max = 2 ** z;
  return x >= 0 && x < max && y >= 0 && y < max;
}

export interface FetchBinaryLike {
  (url: string): Promise<{ ok: boolean; status: number; arrayBuffer(): Promise<ArrayBuffer>; }>;
}

export class TileProxy {
  constructor(
    private readonly cacheDir: string,
    private readonly ttlSeconds: number,
    private readonly fetchImpl: FetchBinaryLike = fetch,
  ) {}

  /** Palauttaa tiilen PNG:nä välimuistista tai lähteestä; null jos lähde ei vastaa. */
  async tile(layer: string, z: number, x: number, y: number, sourceUrl: string): Promise<Buffer | null> {
    const path = join(this.cacheDir, layer, String(z), String(x), `${y}.png`);

    try {
      const info = await stat(path);
      if ((Date.now() - info.mtimeMs) / 1000 < this.ttlSeconds) {
        return await readFile(path);
      }
    } catch {
      // ei välimuistissa
    }

    const res = await this.fetchImpl(sourceUrl).catch(() => null);
    if (!res || !res.ok) return null;
    const buffer = Buffer.from(await res.arrayBuffer());
    try {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, buffer);
    } catch {
      // levyvirhe ei estä palvelemasta tiiltä muistista
    }
    return buffer;
  }
}
