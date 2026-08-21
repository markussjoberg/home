import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { TileProxy, marineTileUrl, terrainTileUrl, validTile } from "../src/tiles.js";

describe("url-rakentajat", () => {
  it("maastokartta: MML WMTS REST, y ennen x:ää", () => {
    expect(terrainTileUrl(12, 2345, 1234, "KEY")).toBe(
      "https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0/maastokartta/default/WGS84_Pseudo-Mercator/12/1234/2345.png?api-key=KEY",
    );
  });

  it("merikartta: korvaa templaten paikat", () => {
    expect(marineTileUrl("https://x/{z}/{y}/{x}.png", 10, 5, 7)).toBe("https://x/10/7/5.png");
  });

  it("validTile hylkää rajojen ulkopuoliset", () => {
    expect(validTile(10, 100, 100)).toBe(true);
    expect(validTile(2, 4, 0)).toBe(false);
    expect(validTile(-1, 0, 0)).toBe(false);
    expect(validTile(3, 1.5, 0)).toBe(false);
  });
});

describe("TileProxy", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "noste-tiles-"));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("hakee lähteestä kerran ja palvelee sitten välimuistista", async () => {
    let calls = 0;
    const fetchImpl = (async () => {
      calls++;
      return new Response(new Uint8Array([1, 2, 3]), { status: 200 });
    }) as unknown as typeof fetch;

    const proxy = new TileProxy(dir, 3600, fetchImpl);
    const first = await proxy.tile("terrain", 10, 1, 2, "https://source/tile.png");
    const second = await proxy.tile("terrain", 10, 1, 2, "https://source/tile.png");

    expect([...first!]).toEqual([1, 2, 3]);
    expect([...second!]).toEqual([1, 2, 3]);
    expect(calls).toBe(1);
  });

  it("palauttaa null kun lähde ei vastaa", async () => {
    const fetchImpl = (async () => new Response("nope", { status: 403 })) as unknown as typeof fetch;
    const proxy = new TileProxy(dir, 3600, fetchImpl);
    expect(await proxy.tile("marine", 10, 1, 2, "https://source/tile.png")).toBeNull();
  });
});
