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
# Kappaleen alku kuumempi -> peräkkäiset kappaleet haarautuvat eri suuntiin
# ennen kuin mallin moodi vetää takaisin; jäähtyy normaaliin ensimmäisten
# tahtien aikana jotta loppu pysyy jäsentyneenä.
WARMUP_BARS = 4
START_BOOST = 0.4


class LLMComposer:
    BEATS_PER_BAR = 3

    def __init__(self, ckpt_path: str, params: LiveParams):
        import torch

        from training.features import GENRES
        from training.model import KVCache, ModelCfg, PosetiiviLM
        from training import tokenizer as tk

        self.torch, self.tk, self.genres = torch, tk, GENRES
        LiveParams.genre_names = GENRES
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
        self._seq = self._prefix()
        self._bar_in_tune = 0
        self._tune_len = 24
        self._prev_bars: list[tuple] = []
        self._ending = False  # "uusi kappale" -nappi: lopetellaan kadenssiin
        self._end_deadline = 0
        self._queue: queue.Queue[list[Note]] = queue.Queue(maxsize=2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()
        atexit.register(self._shutdown)

    def _shutdown(self) -> None:
        # Siisti pysäytys, ettei torch kaadu tulkin sulkeutuessa kesken opin.
        self._stop.set()
        while not self._queue.empty():
            self._queue.get_nowait()
        self._thread.join(timeout=2.0)

    def _prefix(self) -> list[int]:
        t = self.tk.TOK
        return [t["BOS"], t["METER_3"], t["BAR"]]

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
        """Kolmas identtinen tahti peräkkäin tai ABAB-jumi."""
        p = self._prev_bars
        if len(p) >= 2 and sig == p[-1] == p[-2]:
            return True
        return len(p) >= 3 and sig == p[-2] and p[-1] == p[-3]

    def _new_tune(self) -> None:
        """Sävelmä vaihtuu: kontekstiin jää edellisen häntä, laskurit nollille."""
        self._seq = (self._seq + [self.tk.TOK["EOS"]])[-TAIL:] + self._prefix()
        self._bar_in_tune = 0
        self._tune_len = random.randint(16, 32)
        self._prev_bars = []
        self._ending = False
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

    def _generate_bar(self) -> list[Note]:
        torch, t = self.torch, self.tk.TOK
        warmth = 1.0 + START_BOOST * max(0.0, 1.0 - self._bar_in_tune / WARMUP_BARS)
        base_temp = (0.7 + 0.5 * self.params.temperature) * warmth
        bar: list[int] = []
        with torch.no_grad():
            if self._last is None:
                self._last = self._run(self._seq, prime=True)
            if self._ending and self._bar_in_tune >= self._end_deadline:
                # Malli ei päättänyt itse ajoissa — pakotettu piste.
                self._new_tune()
                return []
            for attempt in range(4):
                bar = []
                temp = base_temp * 1.25**attempt
                for _ in range(160):
                    logits = self._last / temp
                    logits[t["PAD"]] = -float("inf")
                    kth = torch.topk(logits, TOP_K).values[-1]
                    logits[logits < kth] = -float("inf")
                    nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
                    if nxt == t["EOS"]:
                        # Piste: biisi päättyi. Uusi lause alkaa, kontekstiin
                        # jää edellisen häntä; väliin hengähdystahti.
                        self._new_tune()
                        return []
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
        notes, _ = self.tk.decode(self._prefix() + bar)
        grid = self.tk.GRID
        # k-näppäimen sävellaji = transponointi (malli generoi C-maailmassa,
        # transpoosiaugmentoinnin ansiosta siirto kuulostaa luontevalta).
        shift = self.params.key % 12
        shift = shift - 12 if shift > 6 else shift
        return [
            Note(beat=n.pos / grid, pitch=min(max(n.pitch + shift, 21), 108),
                 velocity=n.velocity, duration=n.dur / grid, channel=n.channel)
            for n in notes
        ]

    def _worker(self) -> None:
        while not self._stop.is_set():
            self._check_end_request()
            bar = self._generate_bar()
            while not self._stop.is_set():
                if self._check_end_request():
                    break  # nappi painettu: hylkää kädessä oleva tahti
                try:
                    self._queue.put(bar, timeout=0.5)
                    break
                except queue.Full:
                    continue

    def next_bar(self, density: float) -> list[Note] | None:
        """Valmis tahti, tai None jos malli ei vielä ehtinyt (moottori odottaa)."""
        self._density = density
        try:
            return self._queue.get_nowait()
        except queue.Empty:
            return None
