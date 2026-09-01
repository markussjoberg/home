# Noste — wing foil / pump foil / surf -appi + Apple Watch

Sessioiden mittaus kellosta (foiliaika, pumppaukset, lennot), spotit, tuuli- ja
aaltoennusteet sekä maasto- ja merikartat puhelimesta. Konsepti ja arkkitehtuuri:
[KONSEPTI.md](KONSEPTI.md).

## Rakenne

| Polku | Mitä |
|---|---|
| `NostePackage/` | **NosteCore**: analytiikka (pumppu- ja foilitunnistus), ennustehaku, mallit — puhdas Swift + yksikkötestit |
| `Noste/` | iOS-appi: kartta + spotit, ennusteet, sessiohistoria, kellosynkka |
| `NosteWatch/` | watchOS-appi: treenisessio (HealthKit + GPS + kiihtyvyys), offline-ennuste |
| `server/` | **noste-server**: karttatiiliproxy + välimuisti, ennusteiden välimuisti, FMI-havainnot, spotti/sessio-backup, kelivahti (TypeScript + Hono, Docker) |
| `project.yml` | XcodeGen-projektimääritys |

## Käyttöönotto (Mac + Xcode 15+)

```bash
brew install xcodegen
cd home            # tämä repo
xcodegen           # tuottaa Noste.xcodeproj
open Noste.xcodeproj
```

Xcodessa:

1. Aseta molemmille targeteille oma kehittäjätiimi (Signing & Capabilities).
2. `NosteWatch`-targetilla on HealthKit-entitlement valmiina; Xcode lisää
   capabilityn provisiointiin automaattisesti.
3. Käytä tuoretta XcodeGeniä (≥ 2.38): uudet versiot upottavat watchOS-appin
   oikein iPhone-appiin (*Embed Watch Content*). Jos upotus puuttuu tai watch-
   appi upottuu väärin (frameworkina), päivitä XcodeGen tai lisää upotus käsin
   Noste-targetin *General*-välilehdeltä.
4. Aja `NosteWatch`-scheme kelloon/simulaattoriin ja `Noste` puhelimeen.

## Palvelin (Hetzner)

```bash
cd server
cp .env.example .env      # NOSTE_TOKEN, CLIENT_TOKEN, MML_API_KEY, NTFY_URL
docker compose -f docker-compose.prod.yml up -d --build
```

Tuotannossa reverse proxy on **Traefik** (`docker-compose.prod.yml`, verkko
`wp_web`; polkureitti `aihiolabs.com/noste` tarvitsee `priority: 1000`).
Paikalliseen kehitykseen `docker-compose.yml` tai `pnpm dev`. Deploy:
`rsync` `server/`-kansio palvelimelle (`--exclude node_modules --exclude data
--exclude .env`) ja aja compose uudelleen.

Appiin on upotettu palvelimen osoite ja lukutoken (`ServerSettings.builtIn`),
joten kartat ja ennusteet toimivat ilman asetuksia. Oma palvelin + täysi
`NOSTE_TOKEN` asetuksissa avaa synkan ja kelivahdin.

API (kaikki vaativat `Authorization: Bearer <token>` tai `?token=`; lukureitit
toimivat `CLIENT_TOKEN`illa, synkka ja kelivahti vain `NOSTE_TOKEN`illa):
`/api/forecast?lat&lon&sea=1` koottu ennuste · `/api/observation?lat&lon`
FMI-havainto · `/api/openmeteo/{forecast,marine}` läpisyöttö välimuistilla
(myös ECMWF-keskipitkä `models=ecmwf_ifs025` ja historia `past_days`) ·
`/api/wave?lat&lon` FMI:n aaltopoiju + WAM-ennuste ·
`/api/seastate?bbox` poijut ja tuuliasemat alueelta ·
`/api/windfield?bbox` ja `/api/wavefield?bbox` 9×9-hilat Open-Meteosta
kaikille ennustetunneille (kartan tuulipartikkelit ja aaltokenttä) ·
`/api/spotmeta?lat&lon` maastoanalyysi (avoimuus + fetch ilmansuunnittain) ·
`/api/places?lat&lon` rantainfo (OSM + Lipas) ·
`/api/tiles/{terrain,marine,aerial}/{z}/{x}/{y}.png` tiilet ·
`/api/shop/catalog` Lappis-katalogi · `/api/public/spots`, `/api/public/spots/:id/comments`
yhteisön spotit ja kommentit · `/api/spots`, `/api/sessions` synkka ·
`/api/alerts`, `/api/alerts/matches` kelivahti · `/healthz`.

Kehitys: `pnpm install && pnpm test && pnpm dev` (85 testiä, vitest).

## Kartat

- **Maastokartta**: Maanmittauslaitoksen avoin karttakuvapalvelu. API-avain
  palvelimen `.env`-tiedostoon (tai ilman palvelinta appin asetuksiin).
- **Merikartta**: Traficomin avoin rasterimerikartta (WMTS). Tiiliosoite on
  muokattavissa — varmista endpoint ensimmäisellä käyttökerralla.
  Ei navigointikäyttöön.

## Ennusteet

Open-Meteo (tuuli, myös sisävesille; aallokko Itämerelle) — ei API-avainta.
FMI:n havainnot (toteutunut tuuli lähimmältä asemalta) palvelimen
`/api/observation`-reitistä; appin UI:hin vaiheessa 1.

## Testit

`NosteCore`:n algoritmit ovat alustariippumatonta Swiftiä ja testattu
synteettisillä signaaleilla (pumppaussinit, GPS-nopeusprofiilit, kohina- ja
maininkihäiriöt):

```bash
cd NostePackage
swift test
```

Testien odotusarvot on ristiinvalidoitu erillisellä referenssitoteutuksella.
Kynnysarvot (irtoamisnopeudet, pumpun amplitudi) ovat lähtöoletuksia — ne
kalibroidaan ensimmäisten oikeiden sessioiden raakadatalla, joka tallentuu
sessioihin juuri tätä varten.
