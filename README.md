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
3. Jos watch-appi ei näy iPhone-appiin upotettuna (Embed Watch Content),
   lisää se Noste-targetin *General → Frameworks, Libraries, and Embedded
   Content* -kohdasta — XcodeGen-versiot käsittelevät tämän hieman eri tavoin.
4. Aja `NosteWatch`-scheme kelloon/simulaattoriin ja `Noste` puhelimeen.

## Kartat

- **Maastokartta**: Maanmittauslaitoksen avoin karttakuvapalvelu. Hae ilmainen
  API-avain (MML → Rajapinnat → API-avain) ja syötä se appin asetuksiin.
- **Merikartta**: Traficomin avoin rasterimerikartta (WMTS). Tiiliosoite on
  asetuksissa muokattavissa — varmista endpoint ensimmäisellä käyttökerralla.
  Ei navigointikäyttöön.

## Ennusteet

Open-Meteo (tuuli, myös sisävesille; aallokko Itämerelle) — ei API-avainta.
FMI:n havainnot (toteutunut tuuli, aaltopoijut) tulossa vaiheessa 2.

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
