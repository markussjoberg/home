# Posetiivi-projektin tilanne (handoff pilvisessiosta, 2026-07-20)

Mikä: Digitaalinen posetiivi v2 — Raspberry Pi -kampi (hiiren rulla) pyörittää generatiivista musiikkia. Koodi: `markussjoberg/home`, branchi `claude/raspi-lyria-midi-controller-saculz`, kloonattu `~/posetiivi`:iin (venv: `.venv`). Kaikki on committoitu ja pushattu.

Arkkitehtuuri: Python-paketti `posetiivi/` = soitin (asyncio): kampi pyörittää MIDI-kelloa suoraan (tempo seuraa veiviä välittömästi, pysähdys jäädyttää), FluidSynth soittaa. Kolme tahtilähdettä: algoritminen valssisäveltäjä (`midigen.py`), oma MIDI-LLM (`llm_source.py`, oletus) ja Lyria RealTime -pilvimoodi (Lyriaa ei saa lokaaliksi — vain API). `training/` = koko treeniputki (PLAN.md sisältää suunnitelman). `--ui` avaa selainsimulaattorin localhost:8737: scrollaus = veivi, liu'ut = tulevat GPIO-vivut (genrepainot sekoitetaan, surullinen↔iloinen = valence, temperature, rekisteri, soundi- ja tasovivut) — sama `LiveParams`-rajapinta kuin tulevalla raudalla.

Malli: dekooderi-transformer (RMSNorm+RoPE+SwiGLU), REMI-tokenit (~200 sanasto, nuotti = 5 tokenia), per-tahti ehdollistusvektori FiLM:llä: genre-jakauma (16 genreä) + valence/energia/density/rekisteri + fraasipositio (tahti%8) ja biisin etenemä 0→1 ("biisi on lause BOS:sta EOS:iin"). Condition dropout 15 % → CFG. Data: The Session -dumppi (10 537 sävelmää: valssi/polkka/masurkka/marssi, 22 M tokenia), auto-säestys Viterbillä funktionaalisin painoin (V→I, kadenssit fraasirajoille), transpoosiaugmentointi ±6. Nykyinen ckpt `training/ckpt/best.pt` = v3, 1,4 M param, treenattu pilvi-CPU:lla (val loss 0,097).

Keskeiset havainnot (mitattu, demot vs. 30 aitoa sävelmää):

1. v1 jumitti looppeihin (sama tahti 5× peräkkäin; aidoissa max 1–2) → looppivahti samplaukseen (3. identtinen tai ABAB-jumi hylätään, resamplataan kuumemmin).
2. Juurisyy rakenneongelmiin: malli ei tiennyt sijaintiaan biisissä JA treeni-ikkuna (512 tok) ei koskaan näyttänyt kokonaista biisiä (~2100 tok) → fraasi/etenemä-ehdollistus + puolet ikkunoista alkaa BOS:sta + konteksti 1024.
3. v3-tulos: fraasitoisto 8 tahdin päästä 22 % ≈ aitojen 24 % (oli 8 %) — fraasirakenne syntyi, käyttäjän korvatesti vahvisti. Auki: naapuritahtitoistoa yhä liikaa (14 % vs. 1 %), harmoninen rytmi tiheähkö.
4. BUGI TYÖN ALLA: tasajakoinen (2/4, 4/4) generointi romahtaa tyhjiin tahteihin kun CFG guidance >1 — valssi 3/4 toimii. Selvittämättä.
5. Skaalamaski (`--scale hicaz/freygish/...`) = pehmeä logiittipainotus (-6.0; kova -inf romahdutti generoinnin). Toimii ilman treeniä.

Seuraavaksi (sovittu):

1. ISO M4 MAX -TREENI (tähän asti kaikki treenit menivät pilvi-CPU:lla, Macin tehot käyttämättä!): `cd training && python fetch_thesession.py --out data/abc --to-midi data/midi && python prepare_data.py --midi-dir data/midi --genre-map data/midi/genres.csv --out data/prepared && python train.py --data data/prepared --out ckpt --layers 6 --dim 384 --steps 12000` (MPS tunnistuu itse; seq oletus 4096 = 2 biisiä → settisiirtymät; ~1–3 h).
2. 2/4-CFG-bugin korjaus + naapuritoiston kiristys.
3. Uudet datalähteet: sirkus (Mutopia/band organ -rullat), musette, klezmer, choro, longa (SymbTr), FolkWiki (polska + suomalainen polkka — tärkeä!). Genret jo GENRES-listassa (järjestys = ckpt-sopimus, vain lisäyksiä loppuun).
4. Velat kirjattu PLAN.md:hen: tahtilajit 6/8+7/8+9/8 (tarantella, balkan) vaativat tokenisointilaajennuksen; makam-mikrosävelet pitch bendin; pitkä muoto (7 min posetiiviorkesteri) vaatii lopulta hierarkkisen kapellimestariverkon (MusicVAE-idea); KV-cache Pi-inferenssiin.

Käynnistys: `source .venv/bin/activate && python3 -m posetiivi --ui` (config.toml: `source = "llm"`, `soundfont = "FluidR3_GM.sf2"`). Deps: pyfluidsynth, symusic, torch, numpy; brew: fluid-synth, abcmidi.

## Päivitys 2026-07-21: M4 Max -treeni ajettu (lokaali sessio)

v4-malli treenattu M4 Maxilla: 6 kerrosta, d=384, 11,0 M param, seq 4096,
batch 8, 12 000 steppiä, MPS 21 k tok/s (~5,5 h). **Paras val 0.060**
(v3: 0.097) → `training/ckpt/best.pt`. Data: sama The Session -dumppi
uudella putkella (22,2 M tokenia, 17 genren sanasto — vain neljällä on dataa).

Treenikäytännöt M4 Maxille (opittu kantapään kautta):

- Batch 32 × seq 4096 OOM:aa 36 Gt koneella (MPS-attention materialisoi
  4096²-matriisin); batch 16 OOM:aa myös, **batch 8 mahtuu** kun muut
  muistisyöpöt (Lightroom) on suljettu. Swap-tukos hidastaa treenin
  ryömintävauhtiin — tarkista `memory_pressure -Q` ennen starttia.
- `python -u` tai loki ei virtaa; `caffeinate -is -w <pid>` yöajoihin.
- train/val-erot välissä 6000–8000 olivat val-batchien kohinaa, eivät
  ylisovitusta — loppujäähdytys painoi val 0.103 → 0.060.

**2/4-CFG-BUGI KORJAANTUI v4:ssä**: polkka (2/4) ja marssi (4/4) generoituvat
tyhjenemättä guidance 2.0:lla ja 4.0:lla (demot `training/demo/`, tahtitiheys
5,8–7,5 n/s kaikissa). Todennäköinen syy: isompi malli + koko biisin näkevä
treeni-ikkuna vakautti ehdollisen jakauman. Naapuritahtitoistoa ei vielä
mitattu uudelleen — korvatesti ja mittarit tekemättä.

**KV-CACHE ON NYT KRIITTINEN**: uusi generate.py ajaa täyttä kontekstia
ilman cachea → 32 tahdin demo kestää >10 min Macilla (Pi:llä mahdoton).
Laskettu budjetti: cachella ~12 ms/token Pi 5:llä (CFG:n kanssa ~24 ms),
tarve ~28 ms/token → mahtuu. Ajokontekstin voi katkaista ~1024 tokeniin
(attention-kustannus neljännekseen), iso ikkuna oli treeniominaisuus.
