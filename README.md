# Posetiivi 🎵🐒

Digitaalinen posetiivi, versio 2: Raspberry Piin kiinnitetty kampi (hiiren rulla
tangossa) ohjaa **Googlen Lyria RealTime** -musiikkigeneraatiota. Kun veivaat,
musiikki soi ja elää — kun lopetat, musiikki hiljenee.

## Miksi ei täysin lokaalisti?

Lyriaa **ei jaeta mallipainoina**, joten sitä ei voi ajaa Raspilla (eikä millään
muullakaan omalla raudalla). Se on saatavilla vain Gemini API:n kautta
reaaliaikaisena WebSocket-striiminä (`models/lyria-realtime-exp`, vaatii
maksullisen tierin). Googlen avoin sisarmalli Magenta RealTime 2 pyörii
lokaalisti, mutta vaatii Apple Silicon -Macin tai GPU:n — Raspi ei riitä.

Siksi arkkitehtuuri on:

```
[kampi / hiiren rulla]                        [Google Cloud]
        │ evdev (REL_WHEEL)                          │
        ▼                                            │
[Raspberry Pi] ── prompts, density, play/pause ──►  Lyria RealTime
        ▲                                            │
        └────────── PCM 48 kHz s16le stereo ─────────┘
        │
        ▼
   [kaiutin / ALSA]
```

Raspi on siis kampi, ohjain ja äänikortti; itse musiikki generoituu pilvessä.
Raspi 3/4/5 riittää tähän mainiosti — työ on pelkkää WebSocket-liikennettä ja
äänen toistoa.

## Miten kampi vaikuttaa musiikkiin

| Kampi                | Vaikutus                                              |
|----------------------|-------------------------------------------------------|
| Pysähdyksissä        | Ääni feidautuu hiljaiseksi, striimi pauselle          |
| Veivaus alkaa        | Striimi jatkuu, ääni feidautuu kuuluviin              |
| Veivausnopeus        | `density` ja `brightness` (tiheämpi/kirkkaampi soitto)|
| Veivausnopeus (opt.) | Varispeed: toistonopeus elää kammen mukana kuten oikeassa posetiivissa (`[mapping] varispeed = true`) |

Musiikin tyyli määritellään painotettuina prompteina `config.toml`-tiedostossa,
esim. `"street organ waltz"` + `"music box"`.

## Asennus (Raspberry Pi OS)

```bash
sudo apt install python3-pip libportaudio2
git clone <tämä repo> && cd posetiivi
pip install .
```

API-avain (Google AI Studio, maksullinen tier):

```bash
export GEMINI_API_KEY="..."
```

Anna käyttäjälle oikeus lukea input-laitteita:

```bash
sudo usermod -aG input $USER   # kirjaudu ulos ja sisään
```

## Käyttö

```bash
cp config.example.toml config.toml   # muokkaa promptit yms.
python -m posetiivi                  # etsii rullahiiren automaattisesti
python -m posetiivi --mock           # testaus ilman kampea (simuloitu veivi)
python -m posetiivi --list-devices   # listaa input-laitteet
```

Käynnistys bootissa: `systemd/posetiivi.service` (muokkaa polut ja avain,
`sudo cp` → `/etc/systemd/system/` → `systemctl enable`).

## Kehitys ilman Raspia

`--mock` simuloi kampea joka kiihtyy ja hidastuu sinimäisesti, joten koko
putkea (Lyria-yhteys, mappaus, audio) voi testata millä tahansa koneella.
