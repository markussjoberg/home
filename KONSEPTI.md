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

Tuloksena: **pumppujen määrä, kadenssi (pumppua/min), pumppausjaksot ja
aktiivinen pumppausaika**, ja yhdessä foilitunnistuksen kanssa **suorituskohtaiset
tiedot jokaisesta lennosta**: kesto, matka, pumput, frekvenssi, huippu- ja
keskivauhti — sessionäkymän suorituslistassa, ja reitti kartalla samalla
aikaikkunalla (foiliosuudet vihreällä).

### Surffimittarit

- Aallot tunnistetaan nopeuspyrähdyksinä (ride alkaa kun nopeus ylittää melontanopeuden
  selvästi): **aaltojen määrä, pisin laskettu aalto (s ja m), melonta-aika vs. laskuaika**.

### Yhteiset

Kaikissa lajeissa: kesto, matka, maksimi- ja keskinopeus, **syke** (keski/max
yhteenvedossa, koko sarja talteen), kalorit, GPS-jälki. Analytiikka on
`NosteCore`-paketissa puhtaana Swiftinä → sama koodi kellossa, puhelimessa ja
yksikkötesteissä.

### Autopaussi (unohtunut mittari ei pilaa dataa)

Trackerit jäävät päälle, ja autoilu sotkee sitten nopeudet ja matkat. Ilman
karttadataa maissa olo tunnistetaan kolmella säännöllä:

1. **Paikallaan 90 s → autopaussi.** Lähtöpaikan lähellä (< 120 m) jo 45 s:ssa,
   koska lähtöpaikka on yleensä myös lopetuspaikka.
2. **Lähtöpaikalla tullut paussi ei jatku automaattisesti** — sessio on
   todennäköisesti ohi, ja juuri tässä tilanteessa autolla lähtö (esim. 50 km/h
   = wingille "uskottava" 13,9 m/s) sotkisi datan. Vesillä (lepopaussi muualla)
   liikkeelle lähtö jatkaa session automaattisesti 5 s:ssa.
3. **Lajille epäuskottava nopeus paussin aikana** (pumppi > 9 m/s, wing > 20 m/s,
   30 s yhtäjaksoisesti) **tai yli 20 min paussi → sessio päätetään
   automaattisesti** ja yhteenveto talletetaan.

Varmistuksena analyysi suodattaa lajikohtaisen nopeuskaton ylittävät lukemat,
eli maksiminopeudeksi ei koskaan päädy autoilua.

### Mittaus puhelimella (ilman kelloa)

Sessio + -napista Sessiot-välilehdellä: sama analytiikka, autopaussi ja
kaatumissuoja kuin kellossa — GPS ja liikeanturi puhelimesta (pumpputunnistus
toimii parhaiten liivin/vyötärön taskussa), syke ja HealthKit-treeni jäävät
pois. Tämä avaa appin myös kaverille, jolla ei ole kelloa mutta kännykkä kulkee
foilatessa mukana.

## 2. Ennusteet (myös sisämaahan)

Kaksi lähdettä, molemmat ilmaisia ja avaimettomia:

| Lähde | Mitä | Huom |
|---|---|---|
| **Open-Meteo** | Tuuli 10 m (nopeus, puuskat, suunta) tunneittain, useita malleja; `met_no`-malli (MET Nordic ~1 km) kattaa Suomen järviä myöten | Ei API-avainta, CORS ok, ei-kaupallinen ilmainen |
| **ECMWF IFS** (Open-Meteon kautta) | **Keskipitkä ennuste**: päivän maksimituuli, -puuska ja vallitseva suunta 10 vrk — "Pitkä ennuste" -osio spottinäkymässä, tuuli-ikkunaosumat merkittynä | Sama avaimeton rajapinta (`models=ecmwf_ifs025`) |
| **Open-Meteo Marine** | Merkitsevä aallonkorkeus, jaksonaika, suunta; erikseen tuuliaallokko ja maininki | Toimii Itämerellä |
| **Open-Meteo Elevation** | Korkeusprofiilit spotin ympäriltä 8 suuntaan → **maastoanalyysi**: avoimuus ja fetch per ilmansuunta | Copernicus GLO-90; palvelin laskee ja välimuistittaa pysyvästi |
| **FMI avoin data** | *Toteutunut* tuuli lähimmältä havaintoasemalta (WFS) — palvelimen `/api/observation` | "Mitä siellä puhaltaa juuri nyt" — ennusteen rinnalle (appin UI:hin vaiheessa 1) |
| **OSM (Overpass)** | Rantainfra: uimarannat, laiturit, veneluiskat, satamat, parkit, WC:t spotin ympäriltä | Palvelimen `/api/places`, 24 h välimuisti |
| **Lipas** | Viralliset uimarannat ja -paikat (JY:n liikuntapaikkarekisteri) | Samaan `/api/places`-vastaukseen |

**Järviaallot lasketaan** fetch-rajoitteisella JONSWAP-kaavalla: maastoanalyysin
fetch tuulen suunnalta + ennustetuuli → Hs ja Tp (esim. 10 m/s ja 10 km → ~0,5 m
ja 2,9 s; katkaistu täysin kehittyneen merenkäynnin tasoon). Näkyy ennusteriveillä
merkinnällä "(lask.)". Merispoteilla aaltomalli on ensisijainen.

**Maaston avoimuus** näkyy spottinäkymässä ("Avoin: W, SW · Suojainen: NE") —
heuristiikka korkeusdatasta (keskinousu ≤ 2 km tuulen yläpuolella); metsänpeite
(Luke/Copernicus) olisi seuraava tarkennus, korkeus ajaa asian pitkälle.

Kun oma palvelin on käytössä, appin ennustehaut kulkevat sen läpisyötön kautta
(sama muoto, palvelin välimuistittaa 15 min) — muuten suoraan Open-Meteoon.

Ennustenäkymä spottikohtainen: seuraavat 48–72 h, tuuli + puuskat + suunta nuolella,
merispoteille aallokko. Sisävesispotti = sama näkymä ilman aaltoriviä.

**Kelivahti:** spotille asetetaan tuuli-ikkuna (suunnat ilmansuuntina, min/max
m/s) suoraan spottieditorissa, ja **palvelin** johtaa hälytykset spoteista,
tarkistaa ennusteet puolen tunnin välein ja etsii vähintään 2 h osumaikkunat.
Ilmoitukset lähtevät **ntfy:llä** (ilmainen, toimii heti: ntfy-appi puhelimeen,
oma salainen aihe `NTFY_URL`-ympäristömuuttujaan) — sama ikkuna ilmoitetaan
vain kerran. APNs-natiivipushit mahdollinen jatke myöhemmin. Sama tuuli-ikkuna
korostaa osumatunnit ennustenäkymässä ja kellon glancessa.

### Tuulen reittaus ja spotin oppi

Session jälkeen tuuli reittataan: **1–5 tähteä tai "ei riittänyt"** — suoraan
kellon yhteenvedosta (paras hetki) tai puhelimesta. Appi hakee jälkikäteen
toteutuneen tuulen session ajalta (Open-Meteon historia, suunta
vektorikeskiarvona) ja tallettaa parin *(tuuli, tähdet)*.

Näistä spotti oppii (`SpotWindProfile`):

- **Sopivat tuulensuunnat**: ilmansuunnittain keskiarvosana ja määrä; "toimii"
  kun keskiarvo ≥ 3,5 vähintään kahdesta sessiosta. "Ei riittänyt" ei osallistu
  suuntatilastoon (kertoo voimakkuudesta, ei suunnasta).
- **Tähtiennuste**: kun reittauksia on ≥ 5, jokaiselle ennustetunnille
  lasketaan arvio lähimpien koettujen sessioiden painotettuna keskiarvona
  (gaussinen paino nopeus- ja suuntaerolle, σ = 2,5 m/s ja 40°). "Ei riittänyt"
  vetää heikkojen tuulten ennusteen alas. Jos tunti on kaukana kaikesta
  koetusta, ennustetta ei anneta — ei huonoja arvauksia.

Tähdet näkyvät ennusteriveillä ja spotin oppi -kortissa ennustenäkymässä.
Reittaukset kulkevat myös palvelimen varmuuskopioon (sama sessio-id päivittyy,
ei duplikaatteja).

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
  toimivat tuulensuunnat (kelivahtia ja ennustenäkymää varten),
  **yksityinen/julkinen** (julkinen saa näkyä muille kun spottien jako toteutuu).
- Tallennettaessa palvelin laskee spotin maastoanalyysin (avoimuus + fetch) ja
  rantainfon (OSM + Lipas) automaattisesti.
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
