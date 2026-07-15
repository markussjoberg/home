# Posetiivi 🎵🐒

Digitaalinen posetiivi, versio 2: Raspberry Piin kiinnitetty kampi (hiiren
rulla tangossa) pyörittää generatiivista musiikkia. Kun veivaat, musiikki soi
ja elää — kun lopetat, kello pysähtyy kuin oikeassa posetiivissa.

Kaksi koneistoa samassa laitteessa:

| | **MIDI** (oletus) | **Lyria** |
|---|---|---|
| Musiikki | Generatiivinen valssi, FluidSynth-soundit | Googlen Lyria RealTime |
| Missä generoituu | **Lokaalisti Pi:llä** | Googlen pilvessä |
| Vaatii | Ei nettiä, ei APIa | GEMINI_API_KEY, maksullinen tier |
| Kampi → tempo | Suoraan ja välittömästi (MIDI-kello) | Play/pause + density/brightness |
| Suunnan ohjaus | Näppäimet soiton aikana | Promptit configissa |

## Lokaali MIDI-koneisto

Säveltäjä (`midigen.py`) tuottaa loputonta 3/4-valssia tahti kerrallaan:
sointukulut valitaan Markov-ketjulla (vahva paluu toonikalle, dominantti
purkautuu aina), basso–humppa-säestys ja melodia joka suosii sointusäveliä
ja pieniä askelia. Ei neuroverkkoa — siksi se pyörii millä tahansa Pi:llä
ja reagoi parametreihin heti.

**Kampi** ohjaa tempoa (50–170 bpm) ja melodian tiheyttä suoraan: MIDI-kello
etenee vain kun veivaat. Pysähdys vaientaa piiput, ja veivauksen jatkuessa
musiikki jatkuu täsmälleen siitä mihin jäi.

**Suuntaa ohjataan soiton aikana näppäimillä** (uusi arvo kuuluu seuraavasta
tahdista):

```
m      duuri ↔ molli
k / K  sävellaji kvinttiympyrää eteen/taakse
t / T  temperature alas/ylös (kuinka kauas sointusävelistä uskalletaan)
r / R  melodian rekisteri alas/ylös
p      soundi: harmonikka → kirkkourut → harmoni → celesta → soittorasia → piano
```

(GPIO-napit voi kytkeä samoihin parametreihin myöhemmin — LiveParams on
jaettu olio jota voi säätää mistä tahansa taskista.)

## Lyria-koneisto (pilvi)

Lyriaa ei jaeta mallipainoina, joten sitä ei voi ajaa lokaalisti millään
raudalla — se on saatavilla vain Gemini API:n WebSocket-striiminä
(`models/lyria-realtime-exp`). Tässä moodissa Raspi striimaa PCM:ää
(48 kHz s16le stereo) pilvestä ja kampi ohjaa play/pausea, feidejä ja
densityä/brightnessia. Valinnainen varispeed venyttää toistonopeutta kammen
mukana. Käyttö: `--engine lyria` ja `export GEMINI_API_KEY=...`.

## Asennus (Raspberry Pi OS, Pi 3/4/5)

```bash
sudo apt install python3-pip fluidsynth libfluidsynth3 fluid-soundfont-gm
git clone <tämä repo> && cd posetiivi
pip install .              # MIDI-koneisto
pip install .[lyria]       # + pilvikoneisto jos haluat molemmat
sudo usermod -aG input $USER   # oikeus lukea kampea; kirjaudu ulos ja sisään
```

## Käyttö

```bash
cp config.example.toml config.toml   # soundfont, tempoalue, soundit yms.
python -m posetiivi                  # MIDI-koneisto, etsii rullahiiren itse
python -m posetiivi --engine lyria   # pilvikoneisto
python -m posetiivi --mock           # simuloitu kampi (testaus ilman rautaa)
python -m posetiivi --mock --null-synth  # ei ääntäkään, tulostaa nuotit
python -m posetiivi --list-devices   # listaa input-laitteet
```

Käynnistys bootissa: `systemd/posetiivi.service` (muokkaa polut,
`sudo cp` → `/etc/systemd/system/` → `systemctl enable`). MIDI-koneisto ei
tarvitse API-avainta, joten Environment-rivin voi silloin poistaa.

## Kehitys ilman Raspia

`--mock` simuloi kampea joka kiihtyy ja hidastuu sinimäisesti, ja
`--null-synth` korvaa FluidSynthin nuottitulostuksella — koko putken voi
siis testata millä tahansa koneella ilman ääntä ja rautaa.

## Posetiivi-LLM (training/)

Kolmas koneisto työn alla: oma pieni MIDI-kielimalli (~5–10 M parametria),
jota ohjataan **jatkuvilla genre-vivuilla** (esim. 60 % valssi + 40 % tango)
ja mood-akseleilla. Treenataan M4 Maxilla illassa, ajetaan Pi:llä.
Suunnitelma ja valmiit skriptit: [training/PLAN.md](training/PLAN.md) —
putki (prepare → train → generate CFG-vivuilla) on testattu päästä päähän
synteettisellä datalla.

## Jatkoideoita

- Markov-melodia omista MIDI-tiedostoista (v1-posetiivin nauhat tyylilähteeksi)
- GPIO-napit, genre-liu'ut (MCP3008-ADC) ja pyörivä valitsin LiveParams-säätöihin
- RAVE-koneisto neljänneksi moodiksi (reaaliaikainen neurosynteesi pyörii Pi 4/5:llä)
