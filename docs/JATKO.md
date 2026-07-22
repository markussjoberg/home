# Jatkosuunnitelma (päivitetty 2026-07-22 myöhään illalla)

## PÄIVITYS (myöhäisilta): koodikatselmointi löysi 3 oikeaa bugia

Käyttäjä pyysi analyyttistä läpikäyntiä ilman kuuntelua. Löytyi ja
korjattiin (mitattu, git 6c4f007), rehellisin jäljellä olevin puuttein:

1. **Tyhjät tahdit** (todennäköinen syy "katkeaa random-kohdissa"):
   spontaani EOS palautti äänettömän tahdin. Mitattu 3.0% -> 1.8% tahtia
   korjauksen jälkeen. EI täysin nolla — jäljellä olevaa lähdettä ei
   ehditty isoloida. **Seuraava askel**: lisää laskuri joka erottelee
   tuleeko jäljellä oleva tyhjä `_pending`-seedistä (ehkä rest-only-
   tahti aidossa datassa, harmiton) vai `_generate_bar`:n muusta polusta
   (oikea jäljellä oleva bugi).
2. **Rekisterisokea sointuveto** korjattu: veto nyt oktaavin sisällä
   viimeisimmästä saman kanavan sävelestä, ei koko 7 oktaavin alueella.
3. **Äänenkuljetussakko lisätty** (leap-sakko): mitattu ennen/jälkeen
   samalla siemenellä (42): askelin 43%->53% (aito 65%), isoja
   hyppyjä 9%->7% (aito 4%), keskihyppy 3.4->2.8 (aito 2.6). Parannus,
   ei täydellinen — LEAP_PENALTY=0.35 on ensimmäinen arvaus, ei
   kalibroitu tarkasti aitoon jakaumaan asti.

**Sivuvaikutus jota EI ehditty jäljittää**: leap-sakon lisäyksen
jälkeen monsteritahteja ilmestyi 3/400 (0.75%, oli 0 ennen sakkoa).
Mekanismi epäselvä (sakko ei teoriassa koske BAR-tokenin valintaa,
mutta empiirisesti korreloi). **Seuraava askel**: debuggaa tarkasti
mikä monsteritahdeissa tapahtuu (tulosta tahdin token-sekvenssi kun
`len(bar)>threshold`), tai kokeile pienempää LEAP_PENALTY-arvoa
ensin nähdäksesi katoaako ilmiö.

**Käyttäjä ei ole vielä kuunnellut tätä versiota** (pyysi analyyttistä
korjausta ilman kuuntelua, budjetti loppui). Kun jatketaan: kuuntele
ensin tämä (6c4f007) ennen lisää koodimuutoksia.

---

## TÄRKEIN VIESTI SEURAAVALLE SESSIOLLE

Käyttäjä menetti uskonsa illan lopulla: teline (edes eristettynä puhtaana
kokeena rail+seed-pohjan päällä) kuulosti yhä "randomilta, epäharmoniselta,
epäintuitiiviselta". Krediitit loppuivat kesken, ei ehditty juurisyyhyn.

**Ei ole todistettu mahdottomaksi.** Folk-RNN (Sturm ym.) on tutkimuksessa
tunnettu esimerkki: pieni RNN, SAMA datalähde (The Session ABC), tuottaa
vakuuttavia kansansävelmiä muutamalla miljoonalla parametrilla. Raaka
mallikoko (11M) ei siis ole looginen este.

**Mitattu, ei pelkkä tuntuma:** generoidun melodian intervallitilasto on
lähellä aitoa (keskihyppy 2.9 vs aidon 2.6 puolisävelaskelta, ei yhtään
>7 puolisävelaskeleen hyppyä 59 näytteessä) — raaka nuottitaso ei ole
tilastollisesti hullu. "Väärältä kuulostaminen" on siis todennäköisemmin
YHTEISVAIKUTUKSESSA (kisko+seedit+teline+kalibrointi samaan aikaan) kuin
raa'assa kyvyttömyydessä. Sama kuvio toistui KAHDESTI tänään: joka kerta
kun kerroksia pinottiin, tulos huononi; kun palattiin yksinkertaisempaan,
parani.

**Seuraavan session pitäisi tehdä VÄHEMMÄN, ei enempää:**
1. Älä lisää mitään ennen kuin on kuunneltu nykyinen tila (rail+seedit,
   ei telinettä, git 74aab17) rauhassa, useampi kappale.
2. Jos sekin kuulostaa väärältä: kokeile PELKKÄ v4 ILMAN kiskoa/seedejä
   (git 6cf7aa7) — sitä ei ole koskaan A/B-verrattu suoraan tähän
   iltapäivän versioon kunnolla, ja on mahdollista että kisko/seedit
   itsessään (ei vain teline) ovat osa ongelmaa.
3. Harkitse radikaalia yksinkertaistusta: poista kisko kokonaan, luota
   VAIN malliin + seediin. Kisko saattaa taistella mallin omaa (Folk-RNN-
   tasoisesti toimivaksi osoitettua arkkitehtuuria olevaa) oppimaa
   harmoniaa vastaan sen sijaan että auttaisi sitä.
4. Jos mikään yhdistelmä nykyisellä mallilla ei tyydytä: harkitse
   uudelleentreeniä pidemmällä/puhtaammalla datalla ENNEN lisää
   inferenssiaikaisia patcheja — patchit eivät korjaa opittua jakaumaa.

---


Lue tämä ennen kuin muutat mitään. Päivä 07-22 opetti kalliisti: osa
"parannuksista" oli mittarivetoisia näennäisratkaisuja jotka rikkoivat
musiikin. Tämä dokumentti erottaa sen mikä on validoitu siitä mikä oli
spekulaatiota.

## Nykyinen tunnettu hyvä tila (ÄLÄ riko tätä)

- **Live-soitin = d57c5fa-baseline + harmoniakisko + genreseedit, EI
  telinettä** (git d031a98). Käyttäjä kuunnellut ja vahvistanut: kisko +
  seedit korjasivat, teline oli vika. Tämä on nykyinen totuus, ei enää
  kokeilu — kohdellaan uutena baselinena.
  - Muoto/EOS/kadenssilopetus jäävät mallille (kuten alkuperäinen d57c5fa)
  - Sointukisko: funktionaalinen kielioppi (I-IV-V-vi-ii C:ssä), pehmeä
    logit-bias vain sävelvalintahetkiin, kadenssi V->I fraasin loppuun
  - Genreseedit: joka sävelmä alkaa aidon saman genren sävelmän 2
    ensimmäisestä tahdista (sävellajikorjattu C:hen), jatko mallilla
- Malli: `training/ckpt/best.pt` (v4, 6x384, val 0.060, treenattu 07-21).
- UI kunnossa: genre on/off-napit (4), raidat melodia/soinnut/basso,
  tunnelmaliu'ut, autoplay, uusi kappale (välitön tyhjennys + kadenssi),
  kammen jälkihidastus, rulla /200.
- 6 pytestiä (`tests/`), evaluate.py, clean_midi.py, train_queue.sh.

## Tunnettu puute nykyisessä kiskossa (käyttäjän havainto 07-22 ilta)

Sointukielioppi (`CHORD_NEXT`) ja asteikko (`SCALE_PCS`) ovat TÄYSIN
geneerisiä — samat kaikille neljälle genrelle. Valssi, polkka, marssi ja
masurkka saavat identtisen harmonisen raamin, vaikka niillä on omat
maneerinsa (esim. masurkka: korotettu 4./lainasoinnut; valssi: vahva
I-V-I; marssi: staattisempi toonika-pedaali). `_dominant_genre()` on jo
olemassa muualla koodissa muttei kiskon käytössä.

**Seuraava koe (ei vielä tehty, tee YKSILLÄ muutoksella + A/B):**
per-genre `CHORD_NEXT`/`SCALE_PCS`-taulukko `_advance_chord`/`_chord_bias`
-funktioihin, valittuna `_dominant_genre()`:lla. Riski: käsin viritetyt
genresäännöt voivat olla yhtä väärässä kuin mallin oma hallusinaatio jos
musiikkiteoria on arvattu — vaatii oikeaa tietoa per genre, ei arvausta.
Jos ei ole varmaa musiikkiteoriaa käytettävissä, älä keksi — kysy
käyttäjältä tai jätä tekemättä.

## Mitattua faktaa (säilytä nämä opit)

1. **Korva on portti, mittarit ovat diagnooseja.** lag1/lag8-optimointi
   tuotti "päiväkotisoundin" vaikka luvut paranivat. Älä koskaan vie
   liveen mitään pelkän mittarin perusteella.
2. **Val loss valehtelee**: matalin loss (masurkka-spesialisti 0.029) oli
   huonoin malli (toistokollapsi). Älä portaa lossilla.
3. **Spesialistihienosäätö nykyisille 4 genrelle EI kannata** (v4 osaa ne
   jo; hienosäätö vain ylisovitti). Spesialisti on työkalu UUSILLE
   genreille joilla on omaa dataa. `models/<genre>/` on levyllä muttei
   käytössä — älä ota käyttöön ilman korva-A/B:tä.
4. **Seedit vaativat sävellajisiirron C:hen** (korpus on alkuperäisissä
   sävellajeissa; ilman siirtoa bitonaalinen sotku). Koodi: git aa3c921
   (_pick_seed/_transpose_to_c).
5. **Logit-biasit vain sävelvalintahetkiin** (muuten NOTE-massa syrjäyttää
   BAR-tokenin -> monsteritahdit). Sama koskee kaikkia tulevia maskeja.
6. **lag1/lag8-jännite on todellinen** (lämpö korjaa toisen, rikkoo
   toisen) mutta sen ratkaisuyritykset livenä epäonnistuivat korvassa.

## Mikä oli näennäisratkaisua (älä toista sellaisenaan)

- **AABB-teline livessä** — tämä oli vika, ei kisko/seedit (käyttäjän
  korvatuomio 07-22 ilta). Pidä pois livestä.
- Lämpötila 1.1+ (mittarivetoinen virhe)
- Naapuritahtivahti livessä (hylkäsi aidonkin toiston)

Teline elää offline-työkalussa (generate.py: sample_structured;
evaluate.py) kokeiluja varten — ei ole "valmis ominaisuus".

## Prosessisääntö jatkoon (tärkein asia tässä dokumentissa)

1. YKSI muutos kerrallaan baselinen päälle — ei pinoja.
2. A/B-kuuntelu simulaattorissa, käyttäjä tuomarina, ENNEN säilyttämistä.
3. Häviö -> revert heti, kirjaa oppi tähän dokumenttiin.
4. Commitoi baseline-tagilla ennen kokeilua, niin paluu on yksi komento.

## Seuraavat askeleet (halvin ja lupaavin ensin)

1. **A/B: genrekohtainen sointukielioppi/asteikko** nykyisen kiskon
   päälle (ks. "Tunnettu puute" yllä). Yksi muutos, kuuntele, tuomitse.
2. **Uudet genret — V5:n oikea päämäärä.** FolkWiki-scrape jäi kesken
   (sivusto epävakaa; pub/cache osin rikki). Vaihtoehdot: Nottingham
   Music Database ja abcnotation.com (siisti ABC, hae-ja-aja) jenkalle/
   polskalle; tango vaatii clean_midi.py-putken + lähteen. Treeni:
   train_queue.sh toimii (arkkitehtuuri luetaan checkpointista).
   Muista datahygienia (V5.md: SOURCES.md, opt-out).
3. **Pi-valmistelu** kun rauta saapuu: config.tomliin cache_len (~1536)
   + torch-säierajat + karsittu soundfont; mittaa ms/tahti Pi 4 1GB:llä.
4. Fyysinen paneeli V5.md:n mukaan (12-pykälävalitsin jne.) — vasta kun
   ääni on kunnossa.

## Nopeat komennot

```bash
cd ~/posetiivi && .venv/bin/python -u -m posetiivi --ui   # simulaattori
.venv/bin/pytest tests/ -q                                 # testit
.venv/bin/python training/evaluate.py --ckpt training/ckpt/best.pt \
    --genre polkka --data training/data/prepared_polkka --n 12  # diagnoosi
git log --oneline -20                                      # historia
```

Baseline-commit (kisko+seedit, korvavarmistettu): d031a98. Aiempi
puhdas baseline ilman kiskoa/seedejä: 6cf7aa7. Jos jokin hajoaa:
`git diff d031a98 -- posetiivi/` kertoo mitä on muutettu sen jälkeen.
