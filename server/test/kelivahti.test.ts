import { describe, expect, it } from "vitest";
import { directionInSector, matchAlert, type Alert } from "../src/kelivahti.js";
import type { WindHour } from "../src/openmeteo.js";

function hour(i: number, speed: number, direction = 225): WindHour {
  const time = `2026-08-21T${String(i).padStart(2, "0")}:00`;
  return { time, speed, gust: speed * 1.4, direction };
}

const baseAlert: Alert = {
  id: "a1",
  spotId: "s1",
  spotName: "Kotispotti",
  minWind: 8,
  maxWind: 14,
  directionFrom: 180,
  directionTo: 315,
  minHours: 2,
  enabled: true,
};

describe("directionInSector", () => {
  it("tavallinen sektori", () => {
    expect(directionInSector(225, 180, 315)).toBe(true);
    expect(directionInSector(90, 180, 315)).toBe(false);
  });

  it("pohjoisen yli kiertyvä sektori", () => {
    expect(directionInSector(350, 300, 45)).toBe(true);
    expect(directionInSector(10, 300, 45)).toBe(true);
    expect(directionInSector(180, 300, 45)).toBe(false);
  });

  it("ilman sektoria kaikki käy", () => {
    expect(directionInSector(123)).toBe(true);
  });
});

describe("goodDirections (ilmansuuntaindeksit)", () => {
  it("oktantit ohittavat sektorin", () => {
    const alert: Alert = { ...baseAlert, goodDirections: [5, 6] }; // SW, W
    expect(matchAlert(alert, [hour(10, 9, 240), hour(11, 9, 250)])).toHaveLength(1);
    expect(matchAlert(alert, [hour(10, 9, 90), hour(11, 9, 90)])).toHaveLength(0);
  });

  it("pohjoinen kiertyy oikein", () => {
    const alert: Alert = { ...baseAlert, directionFrom: undefined, directionTo: undefined, goodDirections: [0] };
    expect(matchAlert(alert, [hour(10, 9, 355), hour(11, 9, 10)])).toHaveLength(1);
  });
});

describe("matchAlert", () => {
  it("löytää yhtenäisen ikkunan ja raportoi maksimin", () => {
    const wind = [hour(10, 5), hour(11, 9), hour(12, 12), hour(13, 10), hour(14, 4)];
    const windows = matchAlert(baseAlert, wind);
    expect(windows).toHaveLength(1);
    expect(windows[0]).toMatchObject({ start: "2026-08-21T11:00", end: "2026-08-21T13:00", hours: 3, maxSpeed: 12 });
  });

  it("hylkää liian lyhyen ikkunan", () => {
    const wind = [hour(10, 5), hour(11, 9), hour(12, 4), hour(13, 9), hour(14, 4)];
    expect(matchAlert(baseAlert, wind)).toHaveLength(0);
  });

  it("liian kova tuuli katkaisee ikkunan", () => {
    const wind = [hour(10, 9), hour(11, 16), hour(12, 9), hour(13, 9)];
    const windows = matchAlert(baseAlert, wind);
    expect(windows).toHaveLength(1);
    expect(windows[0]!.start).toBe("2026-08-21T12:00");
  });

  it("väärä suunta ei osu", () => {
    const wind = [hour(10, 9, 90), hour(11, 9, 90), hour(12, 9, 90)];
    expect(matchAlert(baseAlert, wind)).toHaveLength(0);
  });

  it("löytää useita ikkunoita", () => {
    const wind = [hour(8, 9), hour(9, 9), hour(10, 2), hour(11, 9), hour(12, 9), hour(13, 9)];
    const windows = matchAlert(baseAlert, wind);
    expect(windows).toHaveLength(2);
    expect(windows[1]!.hours).toBe(3);
  });
});
