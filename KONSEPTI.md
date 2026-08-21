# Noste (työnimi): wing foil / pump foil / surf -sovellus + Apple Watch

*Versio 0.1 — luonnos. Markus Sjöberg, 21.8.2026.*

Yksi sovellus lautavesilajeille: **wing foil, pump foil, surffi** (ja siinä sivussa SUP/downwind). Kolme osaa:

- **Apple Watch -appi** = mittari. Mittaa suoritukset ranteesta: aika, matka, nopeudet, **foiliaika**, **pumppaukset**, lennot. Toimii täysin offline vedessä.
- **iPhone-appi** = tukikohta. Omat spotit, tuuli- ja aaltoennusteet (myös sisävesille), tarkat maastokartat ja merikartat, sessiohistoria ja analyysi.
- **Oma palvelin** (Markuksen Hetzner) = tuki. Karttatiilien proxy ja välimuisti (API-avaimet palvelimella, ei apissa), ennusteiden välimuisti, FMI-havainnot, spottien ja sessioiden varmuuskopio, **kelivahti**. Appi toimii myös ilman palvelinta (hakee suoraan lähteistä), palvelin tekee siitä paremman.

## Prioriteetit (mistä lähdetään)

1. **Suoritusten mittaus mahdollisimman hyvin**: aika, pump foil -pumppaukset, foiliaika.
2. **Tuuli- ja aaltoennuste**, myös sisämaahan (järvet!).
3. **Tarkat maastokartat ja merikartat.**
4. **Kelloon relevantit offline-toiminnot.**
5. **Omien spottien tallennus kännykkäapissa.**

---

## 1. Mittaus (Watch)

Kello on ensisijainen mittalaite: iPhone jää rantaan tai kuivapussiin. Kaikki mittaus
toimii ilman verkkoa; data siirtyy puhelimeen kun yhteys palaa.

### Sessio

- Lajin valinta kellosta: Wing, Pumppi, Surffi, SUP.
- `HKWorkoutSession` (watersports) → treeni näkyy Aktiivisuudessa/Kuntoilussa, syke ja
  kalorit HealthKitistä, GPS-reitti kellon omasta GPS:stä.
- Water lock päälle automaattisesti session alkaessa.
- Mittarinäkymä lajikohtainen (isot numerot, luettavissa märällä ranteella kirkkaassa
  auringossa): aika · nopeus · foiliaika · pumput · syke.

### Foiliajan tunnistus (`FoilPhaseDetector`)

Foililla ajo tunnistetaan kahdesta signaalista:

- **Nopeus** (GPS): lentoon vaaditaan lajikohtainen irtoamisnopeus (wing ~12 km/h,
  pumppi ~8 km/h), kosketukseen pudotaan alemmalla kynnyksellä (hystereesi, ettei
  raja-arvon ympärillä värähtely pilko lentoa).
- **Tärinä** (kiihtyvyysanturi): foililla ajo on *sileää*, runkokosketus ja läpsyminen
  näkyy korkeataajuisena kohinana. Kiihtyvyyden liukuva varianssi erottaa nämä.

Tuloksena per sessio: **foiliaika yhteensä ja %-osuus, lentojen määrä, pisin lento
(aika ja matka), keskinopeus foililla**.

### Pumppausten tunnistus (`PumpDetector`)

Pumppaus näkyy ranteessa jaksollisena pystykiihtyvyytenä ~0,5–1,5 Hz. Tunnistus:
signaalin tasoitus + huippujen poiminta minimietäisyydellä ja -korkeudella
(prominenssi), jotta aallokon keinunta ja käden heilautukset eivät laske pumpuiksi.

Tuloksena: **pumppujen määrä, kadenssi (pumppua/min), pumppausjaksot**, ja pump
foilissa yhdessä foilitunnistuksen kanssa: lentojen määrä ja pisin lento — pumppilajin
tärkein luku.

### Surffimittarit

- Aallot tunnistetaan nopeuspyrähdyksinä (ride alkaa kun nopeus ylittää melontanopeuden
  selvästi): **aaltojen määrä, pisin laskettu aalto (s ja m), melonta-aika vs. laskuaika**.

### Yhteiset

Kaikissa lajeissa: kesto, matka, maksimi- ja keskinopeus, syke, kalorit, GPS-jälki.
Analytiikka on `NosteCore`-paketissa puhtaana Swiftinä → sama koodi kellossa,
puhelimessa ja yksikkötesteissä (testattavissa myös Linuxilla, ilman laitteita).

## 2. Ennusteet (myös sisämaahan)

Kaksi lähdettä, molemmat ilmaisia ja avaimettomia:

| Lähde | Mitä | Huom |
|---|---|---|
| **Open-Meteo** | Tuuli 10 m (nopeus, puuskat, suunta) tunneittain, useita malleja; `met_no`-malli (MET Nordic ~1 km) kattaa Suomen järviä myöten | Ei API-avainta, CORS ok, ei-kaupallinen ilmainen |
| **Open-Meteo Marine** | Merkitsevä aallonkorkeus, jaksonaika, suunta; erikseen tuuliaallokko ja maininki | Toimii Itämerellä; sisävesispoteille näytetään vain tuuli |
| **FMI avoin data** | *Toteutunut* tuuli lähimmältä havaintoasemalta (WFS) — palvelimen `/api/observation` | "Mitä siellä puhaltaa juuri nyt" — ennusteen rinnalle (appin UI:hin vaiheessa 1) |

Kun oma palvelin on käytössä, appin ennustehaut kulkevat sen läpisyötön kautta
(sama muoto, palvelin välimuistittaa 15 min) — muuten suoraan Open-Meteoon.

Ennustenäkymä spottikohtainen: seuraavat 48–72 h, tuuli + puuskat + suunta nuolella,
merispoteille aallokko. Sisävesispotti = sama näkymä ilman aaltoriviä.

**Kelivahti:** spotille asetetaan ehdot (esim. min 8 m/s, max 14 m/s, sektori
SW–NW, vähintään 2 h putkeen) ja **palvelin** tarkistaa ennusteet puolen tunnin
välein ja etsii osumaikkunat. Tämä logiikka on jo palvelimessa (`/api/alerts`);
ilmoituskanava (push/APNs) kytketään vaiheessa 2. Tämä on se ominaisuus joka
säästää turhat ennusteiden tuijottelut.

## 3. Kartat

MapKitin päälle `MKTileOverlay`-tasot:

| Taso | Lähde | Avain |
|---|---|---|
| **Maastokartta** | MML avoin karttakuvapalvelu (WMTS, EPSG:3857) | Ilmainen API-avain — **omalla palvelimella** (proxy), tai ilman palvelinta appin asetuksissa |
| **Merikartta** | Traficomin avoin rasterimerikartta-aineisto (WMTS) | Avoin; endpoint varmistetaan toteutusvaiheessa |
| Perus | Applen kartta | — |

Palvelin välimuistittaa tiilet levylle (30 vrk), joten toistuva selailu ei rasita
MML:n/Traficomin rajapintoja ja tutut alueet latautuvat nopeasti.

Vaihe 2: Väyläviraston avoimet syvyysaineistot (syvyyskäyrät/-alueet WFS) omana
vektoritasona — pumppilaiturien ja foilikivien kannalta kiinnostava.

Vaihe 2: **offline-karttapaketit** spotin ympäriltä (tiilikätkö puhelimeen; kelloon
kevyt versio).

## 4. Offline kellossa

- **Mittaus**: täysin offline (GPS, anturit, HealthKit — ei tarvitse verkkoa eikä puhelinta).
- **Ennustesnapshot**: puhelin työntää suosikkispottien seuraavan 24 h tuulen/aallokon
  kelloon (`WatchConnectivity` applicationContext) aina kun ennuste päivittyy →
  rannassa näkee kellosta "nouseeko tästä vielä", vaikka puhelin jäi autoon.
- **Spotit**: spottilista nimineen ja koordinaatteineen kellossa; session voi
  käynnistää spotille, ja kello näyttää suunnan ja etäisyyden spottiin.
- Vaihe 2: karttatiilet kelloon, komplikaatio (tuuli nyt @ kotispotti).

## 5. Spotit

- Tallennus kartalta (pitkä painallus) tai nykyisestä sijainnista.
- Spotille: nimi, laji(t), tyyppi (meri/järvi), suosikki, muistiinpanot,
  toimivat tuulensuunnat (kelivahtia ja ennustenäkymää varten).
- Suosikkispotit synkataan kelloon ja niiden ennusteet pidetään tuoreina.
- Sessiot linkittyvät automaattisesti lähimpään spottiin.

---

## Tekninen rakenne

```
NostePackage/            SwiftPM-paketti "NosteCore" — puhdas Swift, ei UI:ta
  Sources/NosteCore/     mallit, PumpDetector, FoilPhaseDetector, SessionAnalyzer,
                         OpenMeteoClient, GeoMath
  Tests/                 yksikkötestit synteettisillä signaaleilla
Noste/                   iOS-appi (SwiftUI + SwiftData + MapKit)
NosteWatch/              watchOS-appi (SwiftUI + HealthKit + CoreMotion)
server/                  noste-server (TypeScript/Node + Hono): tiiliproxy +
                         välimuisti, ennusteet, FMI-havainnot, synkka, kelivahti;
                         Docker Compose -paketointi Hetznerille, testit vitestillä
project.yml              XcodeGen-projektimääritys → `xcodegen` tuottaa .xcodeproj
```

- iOS 17 / watchOS 10, SwiftUI kauttaaltaan.
- Data ensisijaisesti omalla laitteella (SwiftData + HealthKit); palvelin toimii
  varmuuskopiona ja kelivahdin ajajana. Yksi käyttäjä, yksi token — ei
  käyttäjähallintaa ennen kuin sille on tarve.
- Kello toimii itsenäisesti (`WKRunsIndependentlyOfCompanionApp`).
- Appi toimii ilman palvelinta; palvelin lisää välimuistin, avaimettomuuden ja
  kelivahdin.

## Vaiheistus

- **V0 (tämä)**: konsepti, projektirunko, NosteCore-algoritmit + testit, iOS- ja
  watch-appien toimiva perusversio (mittaus, spotit, ennuste, karttatasot),
  noste-server (tiiliproxy, ennusteet, FMI, synkka-API, kelivahdin ydin) + deploy
  Hetznerille.
- **V1**: kenttätestaus oikeilla sessioilla → kynnysarvojen kalibrointi lajeittain,
  FMI-havainnot appin UI:hin, sessioiden varmuuskopiointi palvelimelle,
  sessioanalyysi kartalla (foiliosuudet värjättynä jälkeen).
- **V2**: kelivahti-pushit (APNs), offline-karttapaketit, komplikaatiot,
  syvyysaineistot, jibe/tack-tunnistus wingiin, dock start -laskuri pumppiin.
- **Myöhemmin**: vertailut kausittain, vienti (GPX/FIT), kaverit/spottien jako.

## Päätettävää

- Nimi: *Noste* on työnimi (vaihtoehtoja: Foililoki, Liito, Glide).
- Palvelimen domain/alidomain ja Caddy-reititys Hetznerillä.
- Kelivahdin ilmoituskanava: APNs (vaatii Apple-avaimet) vs. välivaiheena
  esim. sähköposti/ntfy.
- Kalibrointidata: ekat oikeat sessiot ratkaisevat kynnysarvot — raakadata talteen
  alusta asti (kiihtyvyys + GPS lokiin), jotta algoritmeja voi ajaa uusiksi jälkikäteen.
