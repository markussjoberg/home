import { describe, expect, it } from "vitest";
import { buildWindUrl, fetchCombinedForecast, parseWind } from "../src/openmeteo.js";

const windBody = {
  hourly: {
    time: ["2026-08-21T10:00", "2026-08-21T11:00", "2026-08-21T12:00"],
    wind_speed_10m: [5.2, null, 7.1],
    wind_gusts_10m: [8.0, 9.0, 10.5],
    wind_direction_10m: [210, 220, 230],
  },
};

const marineBody = {
  hourly: {
    time: ["2026-08-21T10:00"],
    wave_height: [0.7],
    wave_period: [4.2],
    wave_direction: [250],
  },
};

function fakeFetch(handler: (url: string) => { status: number; body: unknown }): typeof fetch {
  return (async (url: string) => {
    const { status, body } = handler(url);
    return new Response(JSON.stringify(body), { status });
  }) as unknown as typeof fetch;
}

describe("parseWind", () => {
  it("pudottaa null-tunnit", () => {
    const hours = parseWind(windBody);
    expect(hours).toHaveLength(2);
    expect(hours[0]).toMatchObject({ time: "2026-08-21T10:00", speed: 5.2, gust: 8.0, direction: 210 });
  });
});

describe("buildWindUrl", () => {
  it("käyttää m/s-yksikköä ja UTC:tä", () => {
    const url = new URL(buildWindUrl(61.5, 23.75, 3));
    expect(url.hostname).toBe("api.open-meteo.com");
    expect(url.searchParams.get("wind_speed_unit")).toBe("ms");
    expect(url.searchParams.get("timezone")).toBe("UTC");
    expect(url.searchParams.get("latitude")).toBe("61.5000");
  });
});

describe("fetchCombinedForecast", () => {
  const now = () => new Date("2026-08-21T12:00:00Z");

  it("yhdistää tuulen ja aallokon merispotille", async () => {
    const fetchImpl = fakeFetch((url) =>
      url.includes("marine") ? { status: 200, body: marineBody } : { status: 200, body: windBody },
    );
    const forecast = await fetchCombinedForecast(60.1, 24.9, true, 3, fetchImpl, now);
    expect(forecast.wind).toHaveLength(2);
    expect(forecast.waves).toHaveLength(1);
    expect(forecast.fetchedAt).toBe("2026-08-21T12:00:00.000Z");
  });

  it("järvispotille ei haeta aallokkoa", async () => {
    let marineCalled = false;
    const fetchImpl = fakeFetch((url) => {
      if (url.includes("marine")) marineCalled = true;
      return { status: 200, body: windBody };
    });
    const forecast = await fetchCombinedForecast(61.5, 23.75, false, 3, fetchImpl, now);
    expect(forecast.waves).toBeNull();
    expect(marineCalled).toBe(false);
  });

  it("aaltohaun virhe ei kaada tuulta", async () => {
    const fetchImpl = fakeFetch((url) =>
      url.includes("marine") ? { status: 500, body: {} } : { status: 200, body: windBody },
    );
    const forecast = await fetchCombinedForecast(60.1, 24.9, true, 3, fetchImpl, now);
    expect(forecast.wind).toHaveLength(2);
    expect(forecast.waves).toBeNull();
  });

  it("tuulihaun virhe kaataa pyynnön", async () => {
    const fetchImpl = fakeFetch(() => ({ status: 500, body: {} }));
    await expect(fetchCombinedForecast(60.1, 24.9, false, 3, fetchImpl, now)).rejects.toThrow("open-meteo 500");
  });

  it("merispotilla tuulen virhe ennen aaltovastausta on tavallinen rejection", async () => {
    // Aaltohaku viipyy, tuuli kaatuu heti: virheen pitää päätyä kutsujalle
    // eikä käsittelemättömäksi rejectioniksi (vitest kaataa ajon sellaisesta).
    const fetchImpl = (async (url: string) => {
      if (url.includes("marine")) {
        await new Promise((resolve) => setTimeout(resolve, 30));
        return new Response(JSON.stringify(marineBody), { status: 200 });
      }
      return new Response("{}", { status: 500 });
    }) as unknown as typeof fetch;
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      await expect(fetchCombinedForecast(60.1, 24.9, true, 3, fetchImpl, now)).rejects.toThrow("open-meteo 500");
      await new Promise((resolve) => setTimeout(resolve, 50));
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    expect(unhandled).toHaveLength(0);
  });
});
