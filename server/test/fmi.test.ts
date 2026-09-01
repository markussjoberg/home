import { describe, expect, it } from "vitest";
import { buildObservationUrl, parseLatestObservation } from "../src/fmi.js";

function element(time: string, name: string, value: string): string {
  return `<wfs:member>
    <BsWfs:BsWfsElement gml:id="x">
      <BsWfs:Location><gml:Point><gml:pos>60.10512 24.97539</gml:pos></gml:Point></BsWfs:Location>
      <BsWfs:Time>${time}</BsWfs:Time>
      <BsWfs:ParameterName>${name}</BsWfs:ParameterName>
      <BsWfs:ParameterValue>${value}</BsWfs:ParameterValue>
    </BsWfs:BsWfsElement>
  </wfs:member>`;
}

describe("parseLatestObservation", () => {
  it("poimii tuoreimman täyden havainnon", () => {
    const xml = `<wfs:FeatureCollection>
      ${element("2026-08-21T11:40:00Z", "ws_10min", "6.1")}
      ${element("2026-08-21T11:40:00Z", "wg_10min", "8.9")}
      ${element("2026-08-21T11:40:00Z", "wd_10min", "230")}
      ${element("2026-08-21T11:50:00Z", "ws_10min", "7.2")}
      ${element("2026-08-21T11:50:00Z", "wg_10min", "9.8")}
      ${element("2026-08-21T11:50:00Z", "wd_10min", "241")}
    </wfs:FeatureCollection>`;

    const obs = parseLatestObservation(xml);
    expect(obs).not.toBeNull();
    expect(obs!.time).toBe("2026-08-21T11:50:00Z");
    expect(obs!.windSpeed).toBe(7.2);
    expect(obs!.windGust).toBe(9.8);
    expect(obs!.windDirection).toBe(241);
    expect(obs!.latitude).toBeCloseTo(60.10512);
  });

  it("ohittaa NaN-arvot ja putoaa edelliseen aikaleimaan", () => {
    const xml = `<x>
      ${element("2026-08-21T11:40:00Z", "ws_10min", "6.1")}
      ${element("2026-08-21T11:40:00Z", "wd_10min", "230")}
      ${element("2026-08-21T11:50:00Z", "ws_10min", "NaN")}
      ${element("2026-08-21T11:50:00Z", "wd_10min", "241")}
    </x>`;

    const obs = parseLatestObservation(xml);
    expect(obs!.time).toBe("2026-08-21T11:40:00Z");
    expect(obs!.windSpeed).toBe(6.1);
    expect(obs!.windGust).toBeNull();
  });

  it("palauttaa null tyhjälle vastaukselle", () => {
    expect(parseLatestObservation("<wfs:FeatureCollection/>")).toBeNull();
  });
});

describe("buildObservationUrl", () => {
  it("rakentaa WFS-kyselyn tunnin ikkunalla", () => {
    const now = () => new Date("2026-08-21T12:00:00Z");
    const url = new URL(buildObservationUrl(60.15, 24.9, now));
    expect(url.hostname).toBe("opendata.fmi.fi");
    expect(url.searchParams.get("latlon")).toBe("60.1500,24.9000");
    expect(url.searchParams.get("parameters")).toBe("ws_10min,wg_10min,wd_10min,t2m");
    expect(url.searchParams.get("starttime")).toBe("2026-08-21T11:00:00.000Z");
  });
});
