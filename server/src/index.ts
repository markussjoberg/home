import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { connectDatabase } from "./db/index.js";

const config = loadConfig();
const database = await connectDatabase(config.databaseUrl, config.dataDir);
console.log(config.databaseUrl ? "tietokanta: Postgres" : `tietokanta: PGlite (${config.dataDir}/pglite)`);
const { app, checkAlerts, runGovernance } = createApp({ config, db: database.db });

const server = serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`noste-server käynnissä portissa ${info.port}`);
  if (!config.apiToken) console.warn("VAROITUS: NOSTE_TOKEN puuttuu — API ei vastaa ennen kuin se on asetettu");
  if (!config.clientToken) console.warn("VAROITUS: CLIENT_TOKEN puuttuu — appin sisäänrakennettu palvelin ei toimi");
  if (!config.mmlApiKey) console.warn("HUOM: MML_API_KEY puuttuu — maastokarttatiilet eivät toimi");
  if (!config.ntfyUrl) console.warn("HUOM: NTFY_URL puuttuu — kelivahti kirjaa osumat vain lokiin");
  if (!config.apnsKeyId) console.warn("HUOM: APNS_KEY_ID/TEAM_ID/KEY_P8 puuttuu — push pois, ilmoitukset vain appin sisällä");
});

// Kelivahti: heti käynnistyksessä (deployn jälkeen ei odoteta puolta tuntia)
// ja sen jälkeen puolen tunnin välein. Osumat talletetaan ja ilmoitetaan ntfy:llä.
const KELIVAHTI_INTERVAL_MS = 30 * 60 * 1000;
function runKelivahti(): void {
  checkAlerts()
    .then((results) => {
      for (const result of results) {
        for (const window of result.windows) {
          console.log(
            `kelivahti: ${result.spotName} — ${window.start}–${window.end} UTC, ` +
              `${window.hours} h, max ${window.maxSpeed.toFixed(1)} m/s`,
          );
        }
      }
    })
    .catch((error) => console.error("kelivahti epäonnistui:", error));
}
runKelivahti();
const kelivahtiTimer = setInterval(() => {
  runKelivahti();
  // Vastustamattomat poistoehdotukset toteutuvat määräajan jälkeen.
  runGovernance().then((ids) => { for (const id of ids) console.log(`poistoehdotus toteutettu: ${id}`); })
    .catch((error) => console.error("poistoehdotukset epäonnistuivat:", error));
}, KELIVAHTI_INTERVAL_MS);

// Docker lähettää SIGTERMin: suljetaan siististi, ettei levykirjoitus jää kesken.
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    clearInterval(kelivahtiTimer);
    server.close(() => { database.close().finally(() => process.exit(0)); });
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
