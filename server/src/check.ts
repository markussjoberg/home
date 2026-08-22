/**
 * Ulkoisten rajapintojen savutesti: aja `pnpm check` koneella jolla on verkko
 * (esim. palvelimella deployn jälkeen). Lukee .env-tiedoston samasta kansiosta.
 * Testaa: MML-maastokarttatiili, Traficom-merikarttatiili, Open-Meteo (tuuli +
 * aallokko) ja FMI-havainto. Kertoo per lähde toimiiko ja mitä korjata.
 */
import { readFileSync } from "node:fs";
import { loadConfig } from "./config.js";
import { buildObservationUrl, parseLatestObservation } from "./fmi.js";
import { buildMarineUrl, buildWindUrl, parseWind } from "./openmeteo.js";
import { marineTileUrl, terrainTileUrl } from "./tiles.js";

// Kevyt .env-lataus ilman riippuvuutta.
function loadDotEnv(path = ".env"): void {
  try {
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (match && !line.trim().startsWith("#") && process.env[match[1]!] === undefined) {
        process.env[match[1]!] = match[2]!;
      }
    }
  } catch {
    // .env puuttuu — käytetään pelkkiä ympäristömuuttujia
  }
}

// Testipiste: Helsingin edusta (meri, joten myös aaltomalli ja merikartta osuvat).
const LAT = 60.15;
const LON = 24.95;
// Sama piste tiilikoordinaatteina, zoom 12 (EPSG:3857).
const TILE = { z: 12, x: 2331, y: 1185 };

let failures = 0;

function ok(name: string, detail: string): void {
  console.log(`  ✓ ${name} — ${detail}`);
}

function fail(name: string, detail: string, hint?: string): void {
  failures++;
  console.log(`  ✗ ${name} — ${detail}`);
  if (hint) console.log(`     → ${hint}`);
}

async function checkTile(name: string, url: string, hint: string): Promise<void> {
  try {
    const res = await fetch(url);
    const type = res.headers.get("content-type") ?? "";
    if (res.ok && type.startsWith("image/")) {
      const bytes = (await res.arrayBuffer()).byteLength;
      ok(name, `${res.status}, ${type}, ${bytes} tavua`);
    } else {
      fail(name, `HTTP ${res.status}, content-type ${type || "?"}`, hint);
    }
  } catch (error) {
    fail(name, String(error), hint);
  }
}

async function main(): Promise<void> {
  loadDotEnv();
  const config = loadConfig();
  console.log("noste-server: ulkoisten rajapintojen tarkistus\n");

  console.log("Kartat:");
  if (config.mmlApiKey) {
    await checkTile(
      "MML maastokartta",
      terrainTileUrl(TILE.z, TILE.x, TILE.y, config.mmlApiKey),
      "Tarkista MML_API_KEY (https://www.maanmittauslaitos.fi/rajapinnat/api-avaimen-ohje)",
    );
  } else {
    fail("MML maastokartta", "MML_API_KEY puuttuu (.env)", "Lisää avain .env-tiedostoon");
  }
  await checkTile(
    "Traficom merikartta",
    marineTileUrl(config.marineTileTemplate, TILE.z, TILE.x, TILE.y),
    "Endpoint voi olla muuttunut — päivitä MARINE_TILE_TEMPLATE (.env)",
  );

  console.log("\nEnnusteet (Open-Meteo):");
  try {
    const res = await fetch(buildWindUrl(LAT, LON, 1));
    const wind = res.ok ? parseWind((await res.json()) as never) : [];
    if (wind.length > 0) {
      ok("tuuli", `${wind.length} tuntia, nyt ${wind[0]!.speed} m/s suunnasta ${wind[0]!.direction}°`);
    } else {
      fail("tuuli", `HTTP ${res.status} tai tyhjä vastaus`);
    }
  } catch (error) {
    fail("tuuli", String(error));
  }
  try {
    const res = await fetch(buildMarineUrl(LAT, LON, 1));
    if (res.ok) {
      ok("aallokko", `HTTP ${res.status}`);
    } else {
      fail("aallokko", `HTTP ${res.status}`, "Aaltomalli ei kata kaikkia rannikkopisteitä — ei kriittinen");
    }
  } catch (error) {
    fail("aallokko", String(error));
  }

  console.log("\nHavainnot (FMI):");
  try {
    const res = await fetch(buildObservationUrl(LAT, LON));
    if (!res.ok) {
      fail("FMI", `HTTP ${res.status}`);
    } else {
      const observation = parseLatestObservation(await res.text());
      if (observation) {
        ok("FMI", `${observation.time}: ${observation.windSpeed} m/s, puuskat ${observation.windGust} m/s, ${observation.windDirection}°`);
      } else {
        fail("FMI", "vastaus saatiin mutta havaintoa ei voitu jäsentää", "Tarkista parseri vasten todellista vastausta");
      }
    }
  } catch (error) {
    fail("FMI", String(error));
  }

  console.log(failures === 0 ? "\nKaikki kunnossa." : `\n${failures} tarkistusta epäonnistui.`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
