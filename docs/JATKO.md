# Jatkosuunnitelma (kirjoitettu 2026-07-22 illalla, session lopuksi)

Lue tämä ennen kuin muutat mitään. Päivä 07-22 opetti kalliisti: osa
"parannuksista" oli mittarivetoisia näennäisratkaisuja jotka rikkoivat
musiikin. Tämä dokumentti erottaa sen mikä on validoitu siitä mikä oli
spekulaatiota.

## Nykyinen tunnettu hyvä tila (ÄLÄ riko tätä)

- **Live-soitin = v4-malli + yksinkertainen generointi** (llm_source.py
  palautettu d57c5fa-tilaan): temp ~0.9, luonnollinen EOS + kadenssi-
  lopetus, vanha jumivahti (3 identtistä / ABAB). Tämä voitti korvatestissä
  kaikki päivän kokeilut. Baseline jota vasten KAIKKI uusi mitataan.
- Malli: `training/ckpt/best.pt` (v4, 6x384, val 0.060, treenattu 07-21).
- UI kunnossa: genre on/off-napit (4), raidat melodia/soinnut/basso,
  tunnelmaliu'ut, autoplay, uusi kappale (välitön tyhjennys + kadenssi),
  kammen jälkihidastus, rulla /200.
- 6 pytestiä (`tests/`), evaluate.py, clean_midi.py, train_queue.sh.

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

- AABB-teline livessä (jäykkä, kuulosti koneelta)
- Harmoniakisko livessä (korjattunakaan ei voittanut baselinea pinossa)
- Lämpötila 1.1+ (mittarivetoinen virhe)
- Naapuritahtivahti livessä (hylkäsi aidonkin toiston)

Nämä elävät offline-työkaluissa (generate.py: sample_structured;
evaluate.py) kokeiluja varten — eivät ole "valmiita ominaisuuksia".

## Prosessisääntö jatkoon (tärkein asia tässä dokumentissa)

1. YKSI muutos kerrallaan baselinen päälle — ei pinoja.
2. A/B-kuuntelu simulaattorissa, käyttäjä tuomarina, ENNEN säilyttämistä.
3. Häviö -> revert heti, kirjaa oppi tähän dokumenttiin.
4. Commitoi baseline-tagilla ennen kokeilua, niin paluu on yksi komento.

## Seuraavat askeleet (halvin ja lupaavin ensin)

1. **A/B: pelkät seedit baselinen päälle.** Lupaavin yksittäinen idea
   (aito genreavaus + vapaus mallille). Poimi aa3c921:stä _pick_seed +
   _transpose_to_c + kevyt _apply_seed MUTTA ilman telinettä: syötä seed
   konteksti-primeen ja emittoi sen tahdit sävelmän alkuna, jatko
   normaalisti. Kuuntele A/B. Voitto -> jää; tappio -> pois ja kirjaa.
2. **A/B: harmoniakisko YKSIN** (ilman telinettä/seedejä), heikommalla
   vedolla (esim. +1.5) ja portitettuna sävelvalintoihin. Vasta jos
   seedit on ratkaistu.
3. **Uudet genret — V5:n oikea päämäärä.** FolkWiki-scrape jäi kesken
   (sivusto epävakaa; pub/cache osin rikki). Vaihtoehdot: Nottingham
   Music Database ja abcnotation.com (siisti ABC, hae-ja-aja) jenkalle/
   polskalle; tango vaatii clean_midi.py-putken + lähteen. Treeni:
   train_queue.sh toimii (arkkitehtuuri luetaan checkpointista).
   Muista datahygienia (V5.md: SOURCES.md, opt-out).
4. **Pi-valmistelu** kun rauta saapuu: config.tomliin cache_len (~1536)
   + torch-säierajat + karsittu soundfont; mittaa ms/tahti Pi 4 1GB:llä.
5. Fyysinen paneeli V5.md:n mukaan (12-pykälävalitsin jne.) — vasta kun
   ääni on kunnossa.

## Nopeat komennot

```bash
cd ~/posetiivi && .venv/bin/python -u -m posetiivi --ui   # simulaattori
.venv/bin/pytest tests/ -q                                 # testit
.venv/bin/python training/evaluate.py --ckpt training/ckpt/best.pt \
    --genre polkka --data training/data/prepared_polkka --n 12  # diagnoosi
git log --oneline -20                                      # historia
```

Baseline-commit: 6cf7aa7 ("Palauta live-soitin eiliseen tunnettuun
hyvään tilaan"). Jos jokin hajoaa: `git diff 6cf7aa7 -- posetiivi/`
kertoo mitä on muutettu sen jälkeen.
