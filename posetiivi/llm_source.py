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

# Harmoniakisko: musiikin säännöt ovat matemaattisesti hallussa, joten
# harmoniaa ei arvota mallilta vaan se annetaan — malli improvisoi raamien
# sisällä. Sointukone C-maailmassa (malli generoi C:ssä, k-siirto
# transponoi jälkikäteen): funktionaalinen kielioppi + kadenssi V->I
# fraasin loppuun (sama logiikka jolla treenidata soinnutettiin).
SCALE_PCS = frozenset({0, 2, 4, 5, 7, 9, 11})  # C-duuri / A-molli
CHORDS = {"I": {0, 4, 7}, "ii": {2, 5, 9}, "IV": {5, 9, 0},
          "V": {7, 11, 2}, "vi": {9, 0, 4}}
CHORD_NEXT = {  # kevyt funktionaalinen kielioppi (painot toistolla)
    "I": ["I", "IV", "V", "vi", "ii", "IV", "V"],
    "ii": ["V", "V", "IV"],
    "IV": ["V", "I", "ii", "V"],
    "V": ["I", "I", "vi"],
    "vi": ["IV", "ii", "V"],
}
CHORD_PULL = 2.5   # sointusävelten veto (logit-lisä)
SCALE_WALL = -6.0  # asteikon ulkopuoliset (pehmeä, ei -inf)
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
        # Melodisesti erotteleva token-joukko looppivahdille (POS+NOTE).
        self._content_toks = frozenset(
            [tk.TOK[f"POS_{i}"] for i in range(16)]
            + [tk.TOK[f"NOTE_{p}"] for p in range(tk.NOTE_LO, tk.NOTE_HI + 1)]
        )
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
        # AABB-teline: malli generoi uniikit fraasit korkealla lämmöllä,
        # emissio toistaa ne puskurista (deterministinen kertaus -> rakenne).
        self._buffer: list[tuple[list, int]] = []  # uniikit tahdit
        self._emit_order: list[int] = []
        self._emit_pos = 0
        self._gen = 0  # "uusi kappale" -sukupolvi (vanhat tahdit mitätöityvät)
        self._chord = "I"
        self._chord_bias_cache: dict[str, object] = {}
        self._plan_form()
        self._apply_seed()  # ensimmäinenkin sävelmä alkaa aidolla avauksella
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

    def _is_loop(self, sig: tuple) -> bool:
        """Jumivahti: kolme identtistä peräkkäin tai ABAB. Naapuritahti-
        Jaccard kokeiltu (07-22) -> hylkäsi myös musiikillisesti aidon
        toiston ja resamplasi kuumemmin = kaaos. Live pitää vain jumit;
        naapurikoe jää offline-generaattoriin kokeiluun."""
        p = self._prev_bars
        if len(p) >= 2 and sig == p[-1] == p[-2]:
            return True
        return len(p) >= 3 and sig == p[-2] and p[-1] == p[-3]

    def _plan_form(self) -> None:
        """Aseta AABB-emissiojärjestys sävelmäpituudesta; nollaa puskuri.
        Malli generoi vain uniikit fraasit (8 tahtia/kirjain), emissio
        kahdentaa ne. tune_len asetetaan uniikkien mitaksi, jotta etenemä
        (progress) nousee 0->1 niiden yli -> B:n loppuun kadenssi."""
        phrase = 8
        n_letters = max(1, round(self._tune_len / (2 * phrase)))
        unique = n_letters * phrase
        self._tune_len = unique
        order: list[int] = []
        for letter in range(n_letters):
            base = letter * phrase
            order += list(range(base, base + phrase)) * 2  # esittely + kertaus
        self._emit_order = order
        self._emit_pos = 0
        self._buffer = []

    def _new_tune(self) -> None:
        """Sävelmä vaihtuu: uusi tahtilaji genren mukaan, kontekstiin edellisen
        häntä, laskurit nollille, uusi AABB-suunnitelma."""
        self.BEATS_PER_BAR = self._tune_meter()  # ennen _prefix():iä
        self._seq = (self._seq + [self.tk.TOK["EOS"]])[-TAIL:] + self._prefix()
        self._bar_in_tune = 0
        self._tune_len = sample_tune_len(random)
        self._prev_bars = []
        self._chord = "I"  # harmoniakisko alkaa toonikasta
        self._plan_form()
        self._apply_seed()  # aito genrealoitus kontekstiin + puskuriin
        self._last = self._run(self._seq, prime=True)

    def _next_structured(self) -> tuple[list, int]:
        """Seuraava emittoitava tahti: uniikki generoidaan, kertaus puskurista."""
        if self._emit_pos >= len(self._emit_order):
            self._new_tune()
        idx = self._emit_order[self._emit_pos]
        self._emit_pos += 1
        if idx < len(self._buffer):
            return self._buffer[idx]        # kertaus: valmis tahti puskurista
        bar = self._generate_bar()          # uusi uniikki tahti
        self._buffer.append(bar)
        return bar

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
        """Genreseed: satunnaisen aidon sävelmän ensimmäiset tahdit
        (BAR-erottimineen). Idiomaattinen avaus, malli jatkaa vapaasti."""
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
                continue  # tahtilajin pitää täsmätä
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
        """Korpussävelmät ovat alkuperäisissä sävellajeissaan (esim. D-duuri
        -> F#/C#) mutta malli + harmoniakisko elävät C-maailmassa. Ilman
        siirtoa avaus ja jatko ovat ERI sävellajeissa = bitonaalinen sotku
        (löytyi lokidiagnoosilla 07-22). Valitse transpoosi joka maksimoi
        asteikko-osuvuuden; token-tason siirto."""
        tk = self.tk
        pitches = []
        for tok in seed:
            name = tk.VOCAB[tok]
            if name.startswith("NOTE_"):
                pitches.append(int(name.split("_")[1]))
        if not pitches:
            return seed
        def score(delta):
            return sum((p + delta) % 12 in SCALE_PCS for p in pitches)
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
        """Syötä seed kontekstiin ja esitäytä puskuri sen tahdeilla —
        kuulija kuulee aidon avauksen, teline kertaa sen osana A-fraasia."""
        seed = self._pick_seed()
        if not seed:
            return
        self._seq += seed
        bar_toks: list[int] = []
        for tok in seed:
            if tok == self.tk.TOK["BAR"]:
                self._buffer.append((self._bar_notes(bar_toks),
                                     self.BEATS_PER_BAR))
                self._prev_bars.append(tuple(bar_toks))
                bar_toks = []
            else:
                bar_toks.append(tok)
        self._bar_in_tune = len(self._buffer)

    def _advance_chord(self) -> None:
        """Tahtikohtainen sointu: kadenssi V->I fraasin (8) loppuun, muuten
        funktionaalinen kielioppi. Teline toistaa tahdit sointuineen, joten
        AABB saa yhtenäisen harmonisen rakenteen."""
        pos = self._bar_in_tune % 8
        if pos == 6:
            self._chord = "V"
        elif pos in (7, 0):
            self._chord = "I"
        else:
            self._chord = random.choice(CHORD_NEXT[self._chord])

    def _chord_bias(self):
        """Logit-lisä NOTE-tokeneille: sointusävelet vetävät (+2.5),
        asteikko vapaa (0), ulkopuoliset painuvat (-6). Pehmeä — malli
        improvisoi raamien sisällä, ei pakoteta."""
        cached = self._chord_bias_cache.get(self._chord)
        if cached is not None:
            return cached
        torch, tk = self.torch, self.tk
        bias = torch.zeros(tk.VOCAB_SIZE)
        pcs = CHORDS[self._chord]
        for p in range(tk.NOTE_LO, tk.NOTE_HI + 1):
            pc = p % 12
            if pc in pcs:
                bias[tk.TOK[f"NOTE_{p}"]] = CHORD_PULL
            elif pc not in SCALE_PCS:
                bias[tk.TOK[f"NOTE_{p}"]] = SCALE_WALL
        self._chord_bias_cache[self._chord] = bias
        return bias

    def request_new_tune(self) -> None:
        """"Uusi kappale" (moottori kutsuu): mitätöi vanhat tahdit ja
        käske työsäie uuteen sävelmään. Sukupolvilaskuri estää vanhan
        sävelmän tahtien vuotamisen jonon läpi."""
        self._gen += 1
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break

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
        """Generoi YKSI uniikki tahti (korkealla lämmöllä). Ei tunerajoja:
        EOS vaimennetaan ja teline (_next_structured) hallitsee pituuden."""
        torch, t = self.torch, self.tk.TOK
        # Korvakalibroitu: temp ~0.9 oletuksella (0.4-liuku). Kokeiltu 1.1
        # mittarien perusteella (07-22) -> kuulosti kaaokselta; mittari ei
        # ole portti, korva on. Kuumennus loivana — teline TOISTAA alun,
        # joten alun kaaos kertautuisi.
        warmth = 1.0 + 0.15 * max(0.0, 1.0 - self._bar_in_tune / WARMUP_BARS)
        base_temp = (0.7 + 0.5 * self.params.temperature) * warmth
        bar: list[int] = []
        self._advance_chord()  # harmoniakisko: tämän tahdin sointu
        chord_bias = self._chord_bias()
        with torch.no_grad():
            if self._last is None:
                self._last = self._run(self._seq, prime=True)
            for attempt in range(4):
                bar = []
                temp = base_temp * 1.25**attempt
                for _ in range(160):
                    logits = self._last / temp
                    # Sointubias VAIN sävelvalintaan (edellinen token CH_*).
                    # Muuten NOTE-massa syrjäyttää BAR-tokenin ja tahti
                    # pursuaa (monsteritahti-bugi, lokidiagnoosi 07-22).
                    if self._seq[-1] in (t["CH_MEL"], t["CH_ACC"]):
                        logits = logits + chord_bias
                    logits[t["PAD"]] = -float("inf")
                    logits[t["EOS"]] = -float("inf")   # teline hallitsee pituuden
                    kth = torch.topk(logits, TOP_K).values[-1]
                    logits[logits < kth] = -float("inf")
                    nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
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
        transponointi (malli generoi C-maailmassa; transpoosiaugmentoinnin
        ansiosta siirto kuulostaa luontevalta)."""
        notes, _ = self.tk.decode(self._prefix() + bar)
        grid = self.tk.GRID
        shift = self.params.key % 12
        shift = shift - 12 if shift > 6 else shift
        return [
            Note(beat=n.pos / grid, pitch=min(max(n.pitch + shift, 21), 108),
                 velocity=n.velocity, duration=n.dur / grid, channel=n.channel)
            for n in notes
        ]

    def _worker(self) -> None:
        gen = self._gen
        while not self._stop.is_set():
            if gen != self._gen:  # nappi painettu -> uusi sävelmä heti
                gen = self._gen
                self._new_tune()
            item = self._next_structured()  # AABB-teline: uniikki tai kertaus
            while not self._stop.is_set():
                if gen != self._gen:
                    break  # vanhentunut tahti pois
                try:
                    self._queue.put((gen, item), timeout=0.5)
                    break
                except queue.Full:
                    continue

    def next_bar(self, density: float) -> tuple[list[Note], int] | None:
        """(tahti, iskua/tahti), tai None jos malli ei vielä ehtinyt."""
        self._density = density
        try:
            gen, item = self._queue.get_nowait()
        except queue.Empty:
            return None
        return item if gen == self._gen else None  # vanha sävelmä pois
