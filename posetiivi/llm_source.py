"""LLM-melodialähde: treenattu posetiivi-LLM tuottaa tahdit.

Toteuttaa saman next_bar(density)-rajapinnan kuin WaltzComposer, joten
MidiEngine ei tiedä eroa. Generointi tapahtuu taustasäikeessä tahti
etukäteen, jottei audiokello koskaan odota mallia; jos malli ei ehdi,
palautetaan hiljainen tahti.

LiveParams-mappaus: genre_ix -> genre-vektori (one-hot; vivut/sekoitukset
tulevat GPIO-liukujen myötä), minor -> valence, temperature -> samplauksen
lämpötila, register -> rekisteriehto. Sävellajia malli ei tunne (key
jätetään huomiotta tässä moodissa).
"""

from __future__ import annotations

import atexit
import queue
import random
import threading

from .midigen import LiveParams, Note

TOP_K = 24
TAIL = 512  # edellisen biisin häntä uuden kontekstiin (settisiirtymät)

# Harmoniakisko: sointukierto annetaan säännöistä, malli improvisoi sen
# sisällä. C-maailmassa (k-siirto transponoi jälkikäteen). EI telinettä —
# muoto jää mallille (korvahypoteesi 07-22: teline oli se vika, kisko+seedit
# korjasivat).
SCALE_PCS = frozenset({0, 2, 4, 5, 7, 9, 11})  # C-duuri / A-molli
CHORDS = {"I": {0, 4, 7}, "ii": {2, 5, 9}, "IV": {5, 9, 0},
          "V": {7, 11, 2}, "vi": {9, 0, 4}}
# Painot MITATTU aidosta datasta (bassoäänten astesiirtymät kaikissa
# tahdeissa, 4 genreä, ~4900 sävelmää, ks. analyysi 07-22) — ei arvattu.
# Löydös: genret jakavat lähes identtisen harmonisen selkärangan (I->V
# 25%, V->I 81-86%, ii->V 61-73%, esikadenssi lähes aina V) — ero
# genrejen välillä on tempossa/rytmissä, ei soinnuissa. Siksi YKSI jaettu
# kielioppi on oikea, ei per-genre-jako (per-genre-erot olisivat kohinaa,
# masurkalla vain 582 sävelmää). Vanha käsin arvattu kielioppi oli
# väärässä suhteessa (V->vi 33% vs mitattu <5%, I->I 14% vs mitattu 51%);
# korjattu vastaamaan mittausta. Pieni osuus (~10%) kussakin on
# mittauskynnyksen (>5%) alle jäänyttä väriotetta (ii/vi), ei tarkkaan
# mitattu mutta säilyttää improvisaatiovaraa.
CHORD_NEXT = {
    "I": ["I"] * 5 + ["V"] * 2 + ["IV"] * 1 + ["ii"] * 1 + ["vi"] * 1,
    "ii": ["V"] * 5 + ["ii"] * 2 + ["I"] * 1,
    "IV": ["V"] * 4 + ["IV"] * 3 + ["I"] * 2,
    "V": ["I"] * 6 + ["V"] * 1,
    "vi": ["ii"] * 5 + ["vi"] * 3 + ["IV"] * 1 + ["I"] * 1,
}
CHORD_PULL = 2.5   # sointusävelten veto (logit-lisä)
SCALE_WALL = -6.0  # asteikon ulkopuoliset (pehmeä)
# Äänenkuljetus: mitattu 07-22 (koodikatselmointi + 1555 intervallia) —
# generoitu melodia hyppii enemmän kuin aito (askelin 43% vs aito 65%,
# isoja hyppyjä >7 puolisävelaskelta 9% vs aito 4%). Sointu/asteikko-
# vedot eivät rajoita HYPYN KOKOA, vain pitch classia. Lisätään erillinen,
# soinnusta riippumaton sakko hypyn koolle (perusmusiikkiteoriaa: askelin
# liike on normi, hyppy poikkeus joka purkautuu) — sama rekisterimuisti
# jota jo käytetään sointuvedon ankkurina.
LEAP_FREE = 2      # puolisävelaskelta ilman sakkoa (sekunti, koherentti)
LEAP_PENALTY = 0.35  # logit-sakko per puolisävelaskel yli vapaan
# Kappaleen alku kuumempi -> peräkkäiset kappaleet haarautuvat eri suuntiin
# ennen kuin mallin moodi vetää takaisin; jäähtyy normaaliin ensimmäisten
# tahtien aikana jotta loppu pysyy jäsentyneenä.
WARMUP_BARS = 4
START_BOOST = 0.4
# Sävelmäpituus (tahtia) arvotaan aitojen The Session -jakaumasta, ei enää
# kiinteästä 16-32:sta joka jätti 37 % todellisuudesta (mm. 64 tahdin pitkän
# muodon) pois. 8:n monikerrat = kokonaisia fraaseja. Sama taulukko
# training/generate.py:ssä (pidä synkassa).
TUNE_LENS = (16, 24, 32, 40, 48, 56, 64, 80, 96)
TUNE_LEN_W = (10, 5, 54, 3, 8, 2, 13, 2, 2)


def sample_tune_len(rng) -> int:
    return rng.choices(TUNE_LENS, weights=TUNE_LEN_W, k=1)[0]


class LLMComposer:
    # BEATS_PER_BAR ei ole enää vakio: tahtilaji valitaan vallitsevan genren
    # mukaan sävelmän alussa (valssi/masurkka 3, polkka 2, marssi 4).
    def __init__(self, ckpt_path: str, params: LiveParams):
        import torch

        from training.features import DATA_GENRES, GENRE_METER, GENRES
        from training.model import KVCache, ModelCfg, PosetiiviLM
        from training import tokenizer as tk

        self.torch, self.tk, self.genres = torch, tk, GENRES
        self._genre_meter = GENRE_METER
        LiveParams.genre_names = GENRES
        LiveParams.data_genres = DATA_GENRES
        ckpt = torch.load(ckpt_path, map_location="cpu")
        self.model = PosetiiviLM(ModelCfg(**ckpt["cfg"]))
        self.model.load_state_dict(ckpt["model"])
        self.model.eval()
        # KV-cache: token maksaa vain itsensä, joten konteksti voi olla koko
        # biisi (ennen: 128 tokenin ikkuna ja silti liian hidasta Pi:lle).
        self._cache = KVCache(self.model.cfg, 1)
        self._last = None  # viimeisimmät logitit; None = prime tarvitaan
        self.params = params
        self._density = 0.5
        self.BEATS_PER_BAR = self._tune_meter()
        self._seq = self._prefix()
        self._bar_in_tune = 0
        self._tune_len = sample_tune_len(random)
        self._prev_bars: list[tuple] = []
        self._ending = False  # "uusi kappale" -nappi: lopetellaan kadenssiin
        self._end_deadline = 0
        self._chord = "I"
        self._last_mel_pitch: int | None = None  # rekisterimuisti (bugikorjaus 07-22)
        self._last_acc_pitch: int | None = None
        self._pending: list[tuple[list[Note], int]] = []  # seed-avaustahdit
        self._apply_seed()
        self._queue: queue.Queue[tuple[list[Note], int]] = queue.Queue(maxsize=2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()
        atexit.register(self._shutdown)

    def _dominant_genre(self) -> str:
        """Vallitseva genre: suurin vipupaino, muuten näppäinohjauksen genre."""
        p = self.params
        best_w, best = 0.0, None
        for name in self.genres:
            w = max(p.genre_weights.get(name, 0.0), 0.0)
            if w > best_w:
                best_w, best = w, name
        return best or self.genres[p.genre_ix % len(self.genres)]

    def _tune_meter(self) -> int:
        """Tahtilaji vallitsevan genren mukaan (oletus 3/4 jos tuntematon)."""
        return self._genre_meter.get(self._dominant_genre(), 3)

    def _shutdown(self) -> None:
        # Siisti pysäytys, ettei torch kaadu tulkin sulkeutuessa kesken opin.
        self._stop.set()
        while not self._queue.empty():
            self._queue.get_nowait()
        self._thread.join(timeout=2.0)

    def _prefix(self) -> list[int]:
        t = self.tk.TOK
        return [t["BOS"], t[f"METER_{self.BEATS_PER_BAR}"], t["BAR"]]

    def _cond(self) -> list[float]:
        p, d = self.params, self._density
        # Vivut voittavat: genrepainoista sekoitettu vektori, muuten one-hot.
        weights = [max(p.genre_weights.get(name, 0.0), 0.0) for name in self.genres]
        if sum(weights) > 0:
            g = [w / sum(weights) for w in weights]
        else:
            g = [0.0] * len(self.genres)
            g[p.genre_ix % len(self.genres)] = 1.0
        register = min(max(0.5 + 0.25 * p.register, 0.0), 1.0)
        valence = p.valence if p.valence is not None else (0.3 if p.minor else 0.75)
        # Fraasipositio ja biisin etenemä: biisi on "lause" BOS:sta EOS:iin.
        phrase = (self._bar_in_tune % 8) / 8.0
        progress = min(self._bar_in_tune / max(self._tune_len - 1, 1), 1.0)
        cond = g + [valence, d, d, register, phrase, progress]
        cd = self.model.cfg.cond_dim  # vanha ckpt: 14 -> pudota rakennepiirteet
        return cond[:cd] + [0.0] * (cd - len(cond))

    _seed_pools: dict[str, object] = {}  # genre -> (tokens, doc-rajat) | None

    def _seed_pool(self, genre: str):
        """Aidot sävelmät seedipankkina: prepared_<genre>/dataset.npz."""
        if genre not in self._seed_pools:
            import numpy as np
            from pathlib import Path
            pool = None
            path = Path("training/data") / f"prepared_{genre}" / "dataset.npz"
            if path.exists():
                z = np.load(path)
                ends = z["doc_ends"]
                starts = np.concatenate(([0], ends[:-1]))
                pool = (z["tokens"], list(zip(starts.tolist(), ends.tolist())))
            self._seed_pools[genre] = pool
        return self._seed_pools[genre]

    def _pick_seed(self, n_bars: int = 2, tries: int = 8) -> list[int] | None:
        """Genreseed: satunnaisen aidon sävelmän ensimmäiset tahdit."""
        pool = self._seed_pool(self._dominant_genre())
        if pool is None:
            return None
        toks, bounds = pool
        t = self.tk.TOK
        for _ in range(tries):
            s, e = random.choice(bounds)
            doc = toks[s:e].tolist()
            if len(doc) < 8 or doc[0] != t["BOS"]:
                continue
            if doc[1] != t[f"METER_{self.BEATS_PER_BAR}"]:
                continue
            out, bars = [], 0
            for tok in doc[3:]:
                if tok == t["EOS"]:
                    break
                out.append(tok)
                if tok == t["BAR"]:
                    bars += 1
                    if bars == n_bars:
                        break
            if bars == n_bars and 8 <= len(out) <= 120:
                return self._transpose_to_c(out)
        return None

    def _transpose_to_c(self, seed: list[int]) -> list[int]:
        """Korpus on alkuperäisissä sävellajeissa; malli + kisko elävät
        C:ssä. Ilman siirtoa avaus ja jatko olisivat eri sävellajeissa
        (bitonaalinen sotku, lokidiagnoosi 07-22)."""
        tk = self.tk
        pitches = [int(tk.VOCAB[tok].split("_")[1]) for tok in seed
                   if tk.VOCAB[tok].startswith("NOTE_")]
        if not pitches:
            return seed
        def score(d):
            return sum((p + d) % 12 in SCALE_PCS for p in pitches)
        best = max(range(-6, 7), key=lambda d: (score(d), -abs(d)))
        if best == 0:
            return seed
        out = []
        for tok in seed:
            name = tk.VOCAB[tok]
            if name.startswith("NOTE_"):
                p = min(max(int(name.split("_")[1]) + best,
                            tk.NOTE_LO), tk.NOTE_HI)
                out.append(tk.TOK[f"NOTE_{p}"])
            else:
                out.append(tok)
        return out

    def _apply_seed(self) -> None:
        """Aito avaus kontekstiin + emittoitavaksi; jatko jää mallille."""
        self._last_mel_pitch = None
        self._last_acc_pitch = None
        seed = self._pick_seed()
        if not seed:
            # Ei seediä (esim. genrellä ei dataa) -> oletusrekisteri.
            self._last_mel_pitch, self._last_acc_pitch = 72, 48
            return
        self._seq += seed
        bar_toks: list[int] = []
        all_bars: list[list[int]] = []
        for tok in seed:
            if tok == self.tk.TOK["BAR"]:
                self._pending.append((self._bar_notes(bar_toks),
                                      self.BEATS_PER_BAR))
                self._prev_bars.append(tuple(bar_toks))
                all_bars.append(bar_toks)
                bar_toks = []
            else:
                bar_toks.append(tok)
        self._bar_in_tune = len(self._pending)
        self._seed_anchor(all_bars)
        # Jos seedissä ei ollut jotain kanavaa (esim. pelkkä melodia),
        # täytä oletuksella ettei rekisteriveto jää olemattomaksi.
        if self._last_mel_pitch is None:
            self._last_mel_pitch = 72
        if self._last_acc_pitch is None:
            self._last_acc_pitch = 48

    def _advance_chord(self) -> None:
        """Tahtikohtainen sointu: kadenssi V->I fraasin loppuun, muuten
        funktionaalinen kielioppi."""
        pos = self._bar_in_tune % 8
        if pos == 6:
            self._chord = "V"
        elif pos in (7, 0):
            self._chord = "I"
        else:
            self._chord = random.choice(CHORD_NEXT[self._chord])

    def _chord_bias(self, anchor: int):
        """Logit-lisä NOTE-tokeneille, kolme kerrosta:
        1. Sointuveto (+2.5, rekisterisidonnainen: täysi voima oktaavin
           sisällä viimeisimmästä saman kanavan sävelestä, muuten 0.3x —
           BUGI löydettiin koodikatselmoinnissa 07-22: vanha versio veti
           yhtä voimakkaasti kaikissa 7 oktaavissa, malli saattoi hypätä
           kauas vain koska pitch class oli "oikea").
        2. Asteikon seinä (-6, rekisteristä riippumaton — väärä pitch
           class on väärä joka oktaavissa).
        3. Äänenkuljetussakko (-0.35/puolisävelaskel yli 2 vapaan) —
           mitattu 07-22: ilman tätä hypyt 43% askelin vs aidon 65%.
           Perusmusiikkiteoriaa (askel on normi), ei genrekohtainen arvaus."""
        torch, tk = self.torch, self.tk
        bias = torch.zeros(tk.VOCAB_SIZE)
        pcs = CHORDS[self._chord]
        for p in range(tk.NOTE_LO, tk.NOTE_HI + 1):
            pc = p % 12
            tok = tk.TOK[f"NOTE_{p}"]
            leap_penalty = -LEAP_PENALTY * max(0, abs(p - anchor) - LEAP_FREE)
            if pc in pcs:
                pull = CHORD_PULL if abs(p - anchor) <= 12 else CHORD_PULL * 0.3
                bias[tok] = pull + leap_penalty
            elif pc not in SCALE_PCS:
                bias[tok] = SCALE_WALL + leap_penalty
            else:
                bias[tok] = leap_penalty
        return bias

    def _seed_anchor(self, bar_toks_list: list[list[int]]) -> None:
        """Aseta rekisterimuisti (viimeisin sävel per kanava) seedin
        viimeisistä nuoteista, jotta ensimmäinen generoitu tahti jatkaa
        seedin rekisteristä eikä hyppää oletusarvoon."""
        tk = self.tk
        for bar_toks in reversed(bar_toks_list):
            for i in range(len(bar_toks) - 1, -1, -1):
                name = tk.VOCAB[bar_toks[i]]
                if name.startswith("NOTE_") and i > 0:
                    ch = tk.VOCAB[bar_toks[i - 1]]
                    pitch = int(name.split("_")[1])
                    if ch == "CH_MEL" and self._last_mel_pitch is None:
                        self._last_mel_pitch = pitch
                    elif ch == "CH_ACC" and self._last_acc_pitch is None:
                        self._last_acc_pitch = pitch
            if self._last_mel_pitch is not None and self._last_acc_pitch is not None:
                return

    def _is_loop(self, sig: tuple) -> bool:
        """Kolmas identtinen tahti peräkkäin tai ABAB-jumi."""
        p = self._prev_bars
        if len(p) >= 2 and sig == p[-1] == p[-2]:
            return True
        return len(p) >= 3 and sig == p[-2] and p[-1] == p[-3]

    def _new_tune(self) -> None:
        """Sävelmä vaihtuu: uusi tahtilaji genren mukaan, kontekstiin edellisen
        häntä, laskurit nollille."""
        self.BEATS_PER_BAR = self._tune_meter()  # ennen _prefix():iä
        self._seq = (self._seq + [self.tk.TOK["EOS"]])[-TAIL:] + self._prefix()
        self._bar_in_tune = 0
        self._tune_len = sample_tune_len(random)
        self._prev_bars = []
        self._ending = False
        self._chord = "I"
        self._pending.clear()
        self._apply_seed()  # uusi sävelmä alkaa aidolla genreavauksella
        self._last = self._run(self._seq, prime=True)

    def _check_end_request(self) -> bool:
        """Kuittaa napin lippu: tyhjennä jono ja aja etenemä loppuun."""
        if not self.params.end_song_request:
            return False
        self.params.end_song_request = False
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break
        self._ending = True
        self._end_deadline = self._bar_in_tune + 4
        # Etenemä ~1 -> malli on oppinut että lause päättyy kadenssiin.
        self._tune_len = min(self._tune_len, self._bar_in_tune + 2)
        return True

    def _run(self, tokens: list[int], prime: bool = False):
        """Aja tokenit mallista cachen läpi; palauta viimeiset logitit."""
        torch = self.torch
        if prime:
            self._cache.rewind(0)
        x = torch.tensor([tokens])
        c = torch.tensor(self._cond()).view(1, 1, -1).expand(1, len(tokens), -1)
        logits, _ = self.model(x, c, cache=self._cache)
        return logits[0, -1]

    def _generate_bar(self) -> tuple[list[Note], int]:
        torch, t = self.torch, self.tk.TOK
        warmth = 1.0 + START_BOOST * max(0.0, 1.0 - self._bar_in_tune / WARMUP_BARS)
        base_temp = (0.7 + 0.5 * self.params.temperature) * warmth
        bar: list[int] = []
        self._advance_chord()  # harmoniakisko: tämän tahdin sointu
        with torch.no_grad():
            if self._last is None:
                self._last = self._run(self._seq, prime=True)
            if self._ending and self._bar_in_tune >= self._end_deadline:
                # Malli ei päättänyt itse ajoissa — pakotettu piste (nappi
                # painettu, moottori on jo vaientanut -> hengähdystahti ok).
                self._new_tune()
                return [], self.BEATS_PER_BAR
            for attempt in range(4):
                bar = []
                temp = base_temp * 1.25**attempt
                for _ in range(160):
                    logits = self._last / temp
                    prev = self._seq[-1]
                    if prev == t["CH_MEL"]:
                        logits = logits + self._chord_bias(self._last_mel_pitch)
                    elif prev == t["CH_ACC"]:
                        logits = logits + self._chord_bias(self._last_acc_pitch)
                    logits[t["PAD"]] = -float("inf")
                    kth = torch.topk(logits, TOP_K).values[-1]
                    logits[logits < kth] = -float("inf")
                    nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
                    if nxt == t["EOS"]:
                        # BUGIKORJAUS 07-22: spontaani EOS (malli päätti
                        # sävelmän kesken, EI napin painallus) ei enää
                        # palauta tyhjää — mitattu 3 % tahdeista täysin
                        # hiljaisia, kuului satunnaisena katkeamisena.
                        # Uuden sävelmän ensimmäinen tahti (seed jos on,
                        # muuten generoitu) HETI niin ettei kuulija koskaan
                        # kuule tyhjää tahtia. _next_item, EI suoraan
                        # _generate_bar — muuten seedin tahdit ohitettaisiin
                        # ja soisivat väärässä järjestyksessä vasta perässä.
                        self._new_tune()
                        return self._next_item()
                    if prev in (t["CH_MEL"], t["CH_ACC"]):
                        name = self.tk.VOCAB[nxt]
                        if name.startswith("NOTE_"):
                            pitch = int(name.split("_")[1])
                            if prev == t["CH_MEL"]:
                                self._last_mel_pitch = pitch
                            else:
                                self._last_acc_pitch = pitch
                    self._seq.append(nxt)
                    if self._cache.len + 1 >= self._cache.max_len:
                        self._last = self._run(self._seq[-TAIL:], prime=True)
                    else:
                        self._last = self._run([nxt])
                    if nxt == t["BAR"]:
                        break
                    bar.append(nxt)
                sig = tuple(bar)
                if bar and self._is_loop(sig):
                    del self._seq[len(self._seq) - len(bar) - 1:]  # hylkää, kuumemmin
                    self._cache.rewind(len(self._seq) - 1)
                    self._last = self._run([self._seq[-1]])
                    continue
                break
        self._prev_bars.append(tuple(bar))
        self._bar_in_tune += 1
        return self._bar_notes(bar), self.BEATS_PER_BAR

    def _bar_notes(self, bar: list[int]) -> list[Note]:
        """Tahdin tokenit -> Note-lista. k-näppäimen sävellaji =
        transponointi (malli generoi C-maailmassa)."""
        notes, _ = self.tk.decode(self._prefix() + bar)
        grid = self.tk.GRID
        shift = self.params.key % 12
        shift = shift - 12 if shift > 6 else shift
        return [
            Note(beat=n.pos / grid, pitch=min(max(n.pitch + shift, 21), 108),
                 velocity=n.velocity, duration=n.dur / grid, channel=n.channel)
            for n in notes
        ]

    def _next_item(self) -> tuple[list[Note], int]:
        """Seuraava emittoitava tahti: seed-avaus jonossa ensin (aito
        alku), muuten mallin generoima. Käytetään sekä workerissa että
        spontaanin EOS-palautumisen yhteydessä (sama järjestyssääntö)."""
        return self._pending.pop(0) if self._pending else self._generate_bar()

    def _worker(self) -> None:
        while not self._stop.is_set():
            self._check_end_request()
            item = self._next_item()
            while not self._stop.is_set():
                if self._check_end_request():
                    break  # nappi painettu: hylkää kädessä oleva tahti
                try:
                    self._queue.put(item, timeout=0.5)
                    break
                except queue.Full:
                    continue

    def next_bar(self, density: float) -> tuple[list[Note], int] | None:
        """(tahti, iskua/tahti), tai None jos malli ei vielä ehtinyt."""
        self._density = density
        try:
            return self._queue.get_nowait()
        except queue.Empty:
            return None
