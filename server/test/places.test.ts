import { describe, expect, it } from "vitest";
import { lipasUrl, nearestPerCategory, overpassQuery, parseLipas, parseOverpass } from "../src/places.js";

describe("overpass", () => {
  it("kysely sisältää kohteet ja säteet", () => {
    const query = overpassQuery(60.1, 24.9);
    expect(query).toContain('nwr["natural"="beach"](around:1500,60.10000,24.90000)');
    expect(query).toContain('nwr["amenity"="parking"](around:800');
    expect(query).toContain("out center");
  });

  it("parsii nodet ja wayt (center), kategorisoi ja laskee etäisyyden", () => {
    const body = {
      elements: [
        { type: "node", lat: 60.101, lon: 24.9, tags: { natural: "beach", name: "Hietsu" } },
        { type: "way", center: { lat: 60.102, lon: 24.902 }, tags: { man_made: "pier" } },
        { type: "node", lat: 60.1005, lon: 24.9, tags: { amenity: "parking" } },
        { type: "node", lat: 60.1, lon: 24.91, tags: { highway: "footway" } }
      ]
    };
    const places = parseOverpass(body, 60.1, 24.9);
    expect(places).toHaveLength(3);
    expect(places[0]).toMatchObject({ category: "Uimaranta", name: "Hietsu", source: "osm" });
    expect(places[0]!.distanceM).toBeGreaterThan(90);
    expect(places[0]!.distanceM).toBeLessThan(130);
    expect(places[1]!.category).toBe("Laituri");
    expect(places[2]!.name).toBeNull();
  });
});

describe("lipas", () => {
  it("url sisältää sijainnin ja tyyppikoodit", () => {
    const url = new URL(lipasUrl("https://lipas.cc.jyu.fi/api", 60.1, 24.9));
    expect(url.pathname).toContain("sports-places");
    expect(url.searchParams.getAll("typeCodes")).toEqual(["203", "3220", "3230", "5150"]);
    expect(url.searchParams.getAll("fields")).toContain("location.coordinates.wgs84");
    expect(url.searchParams.get("closeToLat")).toBe("60.10000");
  });

  it("parsii wgs84-koordinaatit", () => {
    const body = [
      { name: "Melkin ranta", type: { typeCode: 3220 }, location: { coordinates: { wgs84: { lat: 60.103, lon: 24.9 } } } },
      { name: "Uimahalli", type: { typeCode: 3110 }, location: { coordinates: { wgs84: { lat: 60.1, lon: 24.9 } } } },
      { name: "Rikkinäinen", type: { typeCode: 3220 } }
    ];
    const places = parseLipas(body, 60.1, 24.9);
    expect(places).toHaveLength(1);
    expect(places[0]).toMatchObject({ category: "Uimaranta", name: "Melkin ranta", source: "lipas" });
  });
});

describe("nearestPerCategory", () => {
  it("lähin per kategoria, etäisyysjärjestys", () => {
    const nearest = nearestPerCategory([
      { category: "Laituri", name: null, latitude: 0, longitude: 0, distanceM: 500, source: "osm" },
      { category: "Laituri", name: "Lähempi", latitude: 0, longitude: 0, distanceM: 120, source: "osm" },
      { category: "Uimaranta", name: null, latitude: 0, longitude: 0, distanceM: 300, source: "osm" }
    ]);
    expect(nearest).toHaveLength(2);
    expect(nearest[0]).toMatchObject({ category: "Laituri", name: "Lähempi" });
  });
});
