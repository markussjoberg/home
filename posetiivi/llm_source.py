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

WINDOW = 128  # kontekstin pituus generoinnissa (KV-cache olisi seuraava optimointi)
TOP_K = 24


class LLMComposer:
    BEATS_PER_BAR = 3

    def __init__(self, ckpt_path: str, params: LiveParams):
        import torch

        from training.features import GENRES
        from training.model import ModelCfg, PosetiiviLM
        from training import tokenizer as tk

        self.torch, self.tk, self.genres = torch, tk, GENRES
        LiveParams.genre_names = GENRES
        ckpt = torch.load(ckpt_path, map_location="cpu")
        self.model = PosetiiviLM(ModelCfg(**ckpt["cfg"]))
        self.model.load_state_dict(ckpt["model"])
        self.model.eval()
        self.params = params
        self._density = 0.5
        self._seq = self._prefix()
        self._bar_in_tune = 0
        self._tune_len = 24
        self._prev_bars: list[tuple] = []
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

    def _generate_bar(self) -> list[Note]:
        torch, t = self.torch, self.tk.TOK
        base_temp = 0.7 + 0.5 * self.params.temperature
        bar: list[int] = []
        for attempt in range(4):
            bar = []
            temp = base_temp * 1.25**attempt
            with torch.no_grad():
                for _ in range(160):
                    window = self._seq[-WINDOW:]
                    x = torch.tensor([window])
                    c = torch.tensor(self._cond()).view(1, 1, -1).expand(
                        1, len(window), -1
                    )
                    logits, _ = self.model(x, c)
                    logits = logits[0, -1] / temp
                    logits[t["PAD"]] = -float("inf")
                    kth = torch.topk(logits, TOP_K).values[-1]
                    logits[logits < kth] = -float("inf")
                    nxt = int(torch.multinomial(torch.softmax(logits, -1), 1))
                    if nxt == t["EOS"]:
                        # Piste: biisi päättyi. Uusi lause alkaa puhtaalta
                        # pöydältä ja väliin jää hengähdystahti.
                        self._seq = self._prefix()
                        self._bar_in_tune = 0
                        self._tune_len = random.randint(16, 32)
                        self._prev_bars = []
                        return []
                    self._seq.append(nxt)
                    if nxt == t["BAR"]:
                        break
                    bar.append(nxt)
            sig = tuple(bar)
            if bar and self._is_loop(sig):
                del self._seq[len(self._seq) - len(bar) - 1:]  # hylkää, kuumemmin
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
            bar = self._generate_bar()
            while not self._stop.is_set():
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
