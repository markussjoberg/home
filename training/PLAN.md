# Posetiivi-LLM: treenisuunnitelma

Pieni MIDI-kielimalli (~5–10 M parametria), joka säveltää posetiivimusiikkia
ja jota ohjataan **jatkuvilla genre-vivuilla** (esim. 60 % tango + 40 % valssi)
sekä mood-akseleilla. Treenataan M4 Maxilla, ajetaan Raspberry Pi 4/5:llä.

## Arkkitehtuurivalinnat (2026-resepti)

- Dekooderi-transformer: RMSNorm (pre-norm), RoPE, SwiGLU, ei biaseja,
  sidotut embeddingit. Oletuskoko: 6 kerrosta, d=384, 6 päätä ≈ 10 M param.
  Pienempi aloitus (4 kerrosta, d=256 ≈ 3 M) jos dataa on alle ~50 M tokenia.
- Konteksti 1024 tokenia ≈ 20–40 tahtia. Posetiivi ei tarvitse pitkää muistia.
- Treeni: AdamW, lineaarinen warmup 10 % + cosine, bf16 autocast (MPS tukee).

## Ohjaus: jatkuva ehdollistusvektori + CFG

Jokaiselle **tahdille** liitetään ehdollistusvektori:

```
cond = [genre-jakauma (10)] + [valence, energia, density, rekisteri] = 14 floatia
```

- Vektori projisoidaan FiLM-tyylisesti (scale + shift) tahdin kaikkien
  tokenien embeddingeihin. Ei erillisiä kontrollitokeneita → avaruus on
  aidosti jatkuva ja vivut interpoloivat.
- **Condition dropout 15 %** treenissä → malli oppii myös ehdottoman jakauman
  → inferenssissä classifier-free guidance:
  `logits = l_uncond + g * (l_cond - l_uncond)` (g ≈ 1.5–3 terävöittää
  vipujen vaikutusta).
- Varamekanismi sekoitukselle: aja kaksi ehdollistusta ja sekoita jakaumat
  per token (product/mixture of experts). 2× laskenta on pikkumallilla Pi:llä
  merkityksetön.

## Genret ja pehmeät labelit

Sanasto (rakenteellisesti erottuvia, tahtilajiperheittäin):

- 3-jakoiset: valssi, masurkka, polska, menuetti
- tasajakoiset: polkka, jenkka, humppa, marssi, ragtime, tango

Vaihe 1: labelit metadatasta (ABC-korpusten sävelmätyyppi, Lakh/MSD-tagit)
label smoothingilla (0.85 omalle, loput tasan). Vaihe 2: treenaa pieni
luokitin ja korvaa labelit sen **jakaumalla** — oikea musiikki on valmiiksi
sekoittunutta, jolloin treenidata peittää vipuavaruuden välimaaston.
Sama luokitin toimii lopuksi tuomarina: generoi 50/50-pisteestä ja tarkista
että luokitin lukee tuloksen epävarmaksi.

Mood lasketaan analyyttisesti (ei labeleita): valence = duuri/molli +
harmonian väri (Krumhansl-korrelaatio), energia = tempo × density.

## Data

| Lähde | Sisältö | Genret | Labelit |
|---|---|---|---|
| The Session (dumpit GitHubissa) | irlantilainen kansanmusiikki, ABC | valssi, polkka (irlantilainen), masurkka, marssi | tune type -kenttä |
| FolkWiki (folkwiki.se) | pohjoismainen pelimanni, ABC | polska, **suomalais-/pohjoismainen polkka**, jenkka, valssi | sävelmätyyppi |
| abcnotation.com -kokoelmat | valtava ABC-aggregaattori, monta perinnettä | musette, klezmer, tarantella ym. | kokoelmakohtainen |
| Mutopia / kunstderfuge | klassinen, vapaat nuotit/MIDI | sirkus (Fučík, galopit, can-can), menuetti, pitkä muoto | käsin polusta |
| Band organ / fairground -MIDI-kokoelmat | Wurlitzer-rullia digitoituna | sirkus, karusellipotpurit, marssit | käsin polusta |
| Klezmer-MIDI-arkistot | freilach, bulgar, hora | klezmer | käsin polusta |
| Choro-kokoelmat (esim. Casa do Choro -piirin nuotit) | choro 2/4 | choro | käsin polusta |
| Lakh MIDI (LMD-matched) | 45 k MIDIä MSD-linkillä | tango, ragtime, humppa-sukulaiset | Last.fm-tagit |
| SymbTr (Sabancı, GitHub) | ~2200 turkkilaista makam-kappaletta koneluettavana | longa, sirto | usul/makam metadatassa |
| Omat v1-nauhat | posetiivirullat | — | hienosäätövaihe |

**Mikrosävelvelka:** aidot makamit (bayati, rast, saba ym.) käyttävät
neljäsosasäveliä, joita 12-TET NOTE-gridi ei esitä — SymbTr:stä
otetaan aluksi vain 12-TET:iin istuvat makamit (nihavend, hicaz,
kürdi). Täysi makam-tuki vaatisi pitch bend -tokenit tai 24-TET-gridin;
kirjattu jatkoon samaan sarjaan tahtilajivelan kanssa.

**Tahtilajivelka:** tarantella (6/8), balkan (7/8, 9/8) ja muut
yhdistelmä-/epäsymmetriset tahtilajit vaativat tokenisointilaajennuksen:
METER_6/7/9-tokenit ja trioligridi (GRID 4 -> 12 alijakoa/isku tai
erillinen kolmimuunteinen POS-rivi). Tee tämä ennen kuin näiden genrejen
dataa ajetaan sisään — nykyinen 1/16-gridi litistäisi kolmimuunteisuuden.

ABC → MIDI: `abc2midi` (apt/brew: `abcmidi`). Suodatus: tahtilajit 3/4, 2/4
ja 4/4; kesto 8–256 tahtia; kvantisointi 1/16-gridiin.

**Huom. genrekattavuus:** The Session kattaa vain valssin, polkan, masurkan
ja marssin. Genret joilla ei ole dataa jäävät vipuina kohinaksi — aja
ensimmäinen treeni näillä neljällä ja laajenna sanastoa kun FolkWiki
(polska, jenkka) ja tango/ragtime-MIDIt on lisätty.

**Yksiäänisyys:** The Session on melodiadataa. `prepare_data.py` lisää
automaattisesti basson + soinnut (per-tahti kolmisointusovitus) jotta malli
oppii myös säestyskanavan; pois kytkettävissä lipulla `--no-auto-accomp`.

**Augmentointi:** treeni transponoi NOTE-tokeneita satunnaisesti ±6
puolisävelaskelta per näyte — ilmaista dataa (~×12) ja mahdollistaa
sävellajinsiirron ajossa (k-näppäin toimii myös LLM-lähteellä).

Tokenibudjetti: ~30 k sävelmää × ~1 k tokenia = 30 M tokenia → 3–5 M
parametrin malli on turvallinen aloitus (Chinchilla ~20:1, pienelle
tuotantomallille mielellään reilusti yli). Lakh-osajoukolla pääsee
100 M+ tokeniin → 10 M malli.

Kaksivaiheisesti: esitreeni koko aineistolla → hienosäätö (pienempi lr)
valssi/pelimanni-osajoukolla + omilla nauhoilla.

## Tokenisointi (tokenizer.py)

REMI-tyyli, sanasto ~200 tokenia:

```
BOS EOS BAR METER_2 METER_3 METER_4
POS_0..15   (1/16-gridi tahdin sisällä)
CH_MEL CH_ACC
NOTE_21..108
DUR_1..24   (1/16-osina, katkaistaan 24:ään)
VEL_1..4
```

Nuotti = `POS CH NOTE DUR VEL` (5 tokenia). Ehdollistus ei ole tokeneita
vaan rinnakkainen float-matriisi (tahti → cond), joka kohdistetaan
tokeneihin BAR-rajojen mukaan.

## Pitkä muoto (posetiiviorkesteriohjelmisto)

5–10 minuutin kappaleet (marssit, alkusoitot, karusellipotpurit) ovat
~10–25 k tokenia — mikään järkevä konteksti ei kata niitä kokonaan.
Strategia kolmessa portaassa:

1. **Ehdollistus kantaa ikkunan yli**: biisin etenemä (0..1) ja
   fraasipositio kulkevat cond-vektorissa, joten malli tietää sijaintinsa
   muodossa vaikka ikkuna näkee vain osan. Tämä on jo koodissa.
2. **Konteksti 4096–8192 M4 Maxilla** (tämän tiedoston oletukset):
   kattaa 2–4 lyhyttä biisiä tai pitkän kappaleen jakson; malli oppii
   settisiirtymät ja jaksorakenteen.
3. **Hierarkkinen kapellimestari** (MusicVAE-idea, v4): erillinen kevyt
   verkko suunnittelee jaksotason kaaren (A-B-A-coda, sävellajit,
   dynamiikka) ja token-malli täyttää tahdit — ainoa tapa saada aito
   7 min muoto, jossa alku, huippukohta ja loppu.

Pitkän muodon datalähteitä: Lakh MIDI (orkesteri/pop), Mutopia ja
kunstderfuge (klassinen), posetiivi/fairground organ -MIDI-kokoelmat
(Wurlitzer band organ -rullia löytyy MIDI-muodossa harrastajasivuilta).
MAX_BARS on nostettu 1024:ään näitä varten.

## Ajo M4 Maxilla

```bash
cd training
pip install torch symusic numpy
python prepare_data.py --midi-dir data/midi --genre-map data/genres.csv --out data/prepared
python train.py --data data/prepared --out ckpt/ --layers 4 --dim 256   # ~ilta
python generate.py --ckpt ckpt/best.pt --genre "valssi=0.6,tango=0.4" --energy 0.7 --out demo.mid
```

## Vienti Pi:lle ja integraatio posetiiviin

1. `torch.onnx.export` → onnxruntime ARM:lla (tai suoraan torch CPU, 5 M
   malli generoi tokenin ~millisekunnissa — reaaliaika ei ole ongelma).
2. Uusi melodialähde `posetiivi/midigen.py`:n rinnalle: malli generoi tahdin
   kerrallaan, kampi syöttää energian, vivut/napit genrevektorin ja
   valencen. LiveParams laajenee genre-jakaumalla.
3. Tahtilajiperheiden yli sekoitettaessa suurin genrepaino omistaa
   METER-tokenin; muut genret värittävät.

## Riskit

- Embedding-interpolointi voi pettää kulmien välissä → CFG + logit-sekoitus
  varalla; viimeinen varasuunnitelma on hajottaa vivut analyyttisiksi
  akseleiksi (bassokuvio, synkopaatio, ornamentiikka), jotka interpoloituvat
  taatusti.
- Metadata-labelien kohina → luokitinvaihe (2) siivoaa; älä hio vaihetta 1.
- MPS-bf16: jos vanhempi torch kaatuu autocastiin, train.py tippuu fp32:een
  automaattisesti (lippu `--no-amp`).
