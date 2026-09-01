import { describe, expect, it } from "vitest";
import { fetchShopCatalog, parseProducts, parseSizeTerm } from "../src/shop.js";

const wingProduct = {
  id: 72760,
  name: "Duotone Float 2026",
  permalink: "https://lappis.fi/tuote/duotone-float-2026/",
  prices: { price: "92900", currency_minor_unit: 2 },
  attributes: [
    { name: "Wingin koko", terms: [{ name: "2.5m" }, { name: "4.5m" }] },
    { name: "Color", terms: [{ name: "Fuzzy Pink" }] },
  ],
};

describe("lappis-katalogi", () => {
  it("kokotermit parsitaan yksiköistä riippumatta", () => {
    expect(parseSizeTerm("4.5m")).toBe(4.5);
    expect(parseSizeTerm("4,5m")).toBe(4.5);
    expect(parseSizeTerm("95L")).toBe(95);
    expect(parseSizeTerm("1100cm2")).toBe(1100);
    expect(parseSizeTerm("One size")).toBeNull();
  });

  it("tuote laajenee riviksi per koko, hinta euroina ja vuosi nimestä", () => {
    const items = parseProducts([wingProduct], "wing");
    expect(items).toHaveLength(2);
    expect(items[0]).toMatchObject({
      id: "72760-2.5", type: "wing", size: 2.5, year: 2026, price: 929,
      url: "https://lappis.fi/tuote/duotone-float-2026/",
    });
    expect(items[1]!.size).toBe(4.5);
  });

  it("kooton tuote tulee yhtenä rivinä, nollahintainen ei lainkaan", () => {
    const noSize = { ...wingProduct, id: 1, attributes: [] };
    const noPrice = { ...wingProduct, id: 2, prices: { price: "0", currency_minor_unit: 2 } };
    const items = parseProducts([noSize, noPrice], "board");
    expect(items).toHaveLength(1);
    expect(items[0]!.size).toBeNull();
  });

  it("haku kokoaa kategoriat ja heittää tyhjästä", async () => {
    const ok = (async (url: string) => new Response(
      JSON.stringify(url.includes("category=1454") ? [wingProduct] : []),
      { status: 200 },
    )) as unknown as typeof fetch;
    const catalog = await fetchShopCatalog(ok, "https://lappis.fi/wp-json/wc/store/v1", () => new Date("2026-08-30T12:00:00Z"));
    expect(catalog.items).toHaveLength(2);
    expect(catalog.store).toBe("Lappis");

    const empty = (async () => new Response("[]", { status: 200 })) as unknown as typeof fetch;
    await expect(fetchShopCatalog(empty)).rejects.toThrow();
  });
});
