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
cp .env.example .env      # täytä NOSTE_TOKEN ja MML_API_KEY
docker compose up -d --build
```

Caddyyn (palvelimella on jo Caddy ajossa):

```
noste.esimerkki.fi {
    reverse_proxy 127.0.0.1:8080
}
```

Appin asetuksiin palvelimen osoite + token → kartat ja ennusteet kulkevat
palvelimen kautta, eikä appiin tarvita mitään avaimia.

API (kaikki vaativat `Authorization: Bearer <token>` tai `?token=`):
`/api/forecast?lat&lon&sea=1` koottu ennuste · `/api/observation?lat&lon`
FMI-havainto · `/api/openmeteo/{forecast,marine}` läpisyöttö välimuistilla
(myös ECMWF-keskipitkä `models=ecmwf_ifs025` ja historia `past_days`) ·
`/api/spotmeta?lat&lon` maastoanalyysi (avoimuus + fetch ilmansuunnittain) ·
`/api/places?lat&lon` rantainfo (OSM + Lipas) ·
`/api/tiles/{terrain,marine}/{z}/{x}/{y}.png` tiilet · `/api/spots`,
`/api/sessions` synkka · `/api/alerts`, `/api/alerts/matches` kelivahti.

Kehitys: `pnpm install && pnpm test && pnpm dev` (31 testiä, vitest).

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
