import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const { app, checkAlerts } = createApp({ config });

serve({ fetch: app.fetch, port: config.port }, (info) => {
  console.log(`noste-server käynnissä portissa ${info.port}`);
  if (!config.apiToken) console.warn("VAROITUS: NOSTE_TOKEN puuttuu — API ei vastaa ennen kuin se on asetettu");
  if (!config.mmlApiKey) console.warn("HUOM: MML_API_KEY puuttuu — maastokarttatiilet eivät toimi");
});

// Kelivahti: tarkista puolen tunnin välein. Osumat talletetaan dataan ja lokiin;
// push-ilmoitukset (APNs) kytketään myöhemmin.
const KELIVAHTI_INTERVAL_MS = 30 * 60 * 1000;
setInterval(() => {
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
}, KELIVAHTI_INTERVAL_MS);
