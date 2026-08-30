/**
 * Lappis.fi-integraatio: kaupan julkinen WooCommerce Store API. Palvelin hakee
 * ja välimuistittaa katalogin (appi ei koskaan kutsu kauppaa suoraan), ja
 * GearAdvisor appissa poimii ehdotukset. Ei kaupallista sopimusta (vielä) —
 * data on kaupan julkista tuotetietoa ja linkit vievät kauppaan.
 */
import type { FetchLike } from "./places.js";

export const LAPPIS_STORE_API = "https://lappis.fi/wp-json/wc/store/v1";

/** Kategoria → kalustotyyppi. Tarkistettu Store API:sta 2026-08. */
export const SHOP_CATEGORIES: { id: number; type: ShopItemType }[] = [
  { id: 1454, type: "wing" },  // Uudet wingit
  { id: 1594, type: "board" }, // Foil-laudat
  { id: 1467, type: "foil" },  // Wingfoil hydrofoil etusiivet
];

export type ShopItemType = "wing" | "board" | "foil";

export interface ShopItem {
  id: string;
  type: ShopItemType;
  name: string;
  /** Siivet m², laudat l, foilit cm²; null jos ei pääteltävissä. */
  size: number | null;
  year: number | null;
  /** Hinta euroina. */
  price: number;
  url: string;
}

export interface ShopCatalog {
  fetchedAt: string;
  store: string;
  items: ShopItem[];
}

interface StoreProduct {
  id: number;
  name: string;
  permalink: string;
  prices?: { price?: string; currency_minor_unit?: number };
  attributes?: { name?: string; terms?: { name?: string }[] }[];
}

/** Parsii kokotermin: "4.5m" → 4.5, "95L" → 95, "1100cm2" → 1100. */
export function parseSizeTerm(term: string): number | null {
  const match = term.replace(",", ".").match(/(\d+(?:\.\d+)?)/);
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) && value > 0 ? value : null;
}

export function parseProducts(body: unknown, type: ShopItemType): ShopItem[] {
  const products = Array.isArray(body) ? (body as StoreProduct[]) : [];
  const items: ShopItem[] = [];
  for (const product of products) {
    if (!product?.name || !product.permalink) continue;
    const minor = product.prices?.currency_minor_unit ?? 2;
    const price = Math.round(Number(product.prices?.price ?? 0) / 10 ** minor);
    if (!Number.isFinite(price) || price <= 0) continue;
    const year = Number((product.name.match(/\b(20\d{2})\b/) ?? [])[1]) || null;

    // Kokoattribuutti ("Wingin koko", "Koko", …): yksi rivi per koko, jotta
    // suosittelija voi valita tavoitetta lähimmän. Ilman attribuuttia yksi rivi.
    const sizeAttr = product.attributes?.find((a) => (a.name ?? "").toLowerCase().includes("koko"));
    const sizes = (sizeAttr?.terms ?? [])
      .map((t) => parseSizeTerm(t.name ?? ""))
      .filter((s): s is number => s !== null);
    if (sizes.length > 0) {
      for (const size of sizes) {
        items.push({
          id: `${product.id}-${size}`,
          type,
          name: product.name,
          size,
          year,
          price,
          url: product.permalink,
        });
      }
    } else {
      items.push({ id: String(product.id), type, name: product.name, size: null, year, price, url: product.permalink });
    }
  }
  return items;
}

/** Hakee koko katalogin kategoria kerrallaan. Heittää, jos mitään ei saatu. */
export async function fetchShopCatalog(
  fetchImpl: FetchLike = fetch,
  base = LAPPIS_STORE_API,
  now: () => Date = () => new Date(),
): Promise<ShopCatalog> {
  const items: ShopItem[] = [];
  for (const category of SHOP_CATEGORIES) {
    const url = `${base}/products?category=${category.id}&per_page=100`;
    try {
      const res = await fetchImpl(url);
      if (!res.ok) continue;
      items.push(...parseProducts(await res.json(), category.type));
    } catch {
      // Yksi kategoria saa epäonnistua — muut kelpaavat silti.
    }
  }
  if (items.length === 0) {
    throw new Error("Kaupan katalogi jäi tyhjäksi");
  }
  return { fetchedAt: now().toISOString(), store: "Lappis", items };
}
