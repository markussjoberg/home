"""PCM-toisto: rengaspuskuri, kampeen sidottu feidaus ja valinnainen varispeed.

Lyria RealTime striimaa raakaa PCM:ää: 48 kHz, 16-bit, stereo. Chunkit
puretaan float32-rengaspuskuriin, josta sounddevicen callback lukee.
Varispeed-tilassa lukukohtaa askelletaan kammen nopeuden mukaan ja näytteet
interpoloidaan lineaarisesti — kuulostaa mekaaniselta posetiivilta.
"""

from __future__ import annotations

import threading

import numpy as np
import sounddevice as sd

from .config import AudioCfg, MappingCfg

SAMPLE_RATE = 48_000
CHANNELS = 2


class Player:
    def __init__(self, audio_cfg: AudioCfg, mapping_cfg: MappingCfg):
        self.cfg = audio_cfg
        self.map = mapping_cfg
        self._lock = threading.Lock()
        self._buf = np.zeros((SAMPLE_RATE * 30, CHANNELS), dtype=np.float32)
        self._write = 0  # kirjoitusindeksi (näytteinä, kasvaa rajatta)
        self._read = 0.0  # lukukohta, float varispeediä varten
        self._gain = 0.0  # nykyinen feidattu vahvistus 0..1
        self.target_gain = 0.0  # main.py asettaa: 1.0 kun veivataan
        self.rate = 1.0  # main.py asettaa: toistonopeus varispeedissä
        self._prebuffered = False
        self._stream: sd.OutputStream | None = None

    def start(self) -> None:
        device = self.cfg.output_device or None
        try:
            device = int(device) if device is not None else None
        except ValueError:
            pass
        self._stream = sd.OutputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            device=device,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> None:
        if self._stream:
            self._stream.stop()
            self._stream.close()

    def feed(self, pcm_bytes: bytes) -> None:
        """Syötä Lyrian audiochunk (s16le stereo) puskuriin."""
        samples = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32)
        samples = (samples / 32768.0).reshape(-1, CHANNELS)
        n = len(self._buf)
        with self._lock:
            # Jos puskuri on jäämässä liian kauas jälkeen (esim. pitkän
            # pausen jälkeen), hyppää lukukohta lähemmäs tuoretta ääntä.
            if self._write - self._read > n - len(samples):
                self._read = self._write - SAMPLE_RATE * self.cfg.prebuffer_sec
            start = self._write % n
            end = start + len(samples)
            if end <= n:
                self._buf[start:end] = samples
            else:
                k = n - start
                self._buf[start:] = samples[:k]
                self._buf[: end - n] = samples[k:]
            self._write += len(samples)
            if not self._prebuffered and self._write >= SAMPLE_RATE * self.cfg.prebuffer_sec:
                self._prebuffered = True

    def _callback(self, out: np.ndarray, frames: int, _time, _status) -> None:
        out.fill(0.0)
        with self._lock:
            if not self._prebuffered:
                return
            # Kampi pysähdyksissä ja feidi valmis: lukukohta ei etene, joten
            # musiikki jatkuu tauon jälkeen siitä mihin jäi.
            if self._gain <= 0.0 and self.target_gain <= 0.0:
                return

            fade_step = 1.0 / max(self.cfg.fade_sec * SAMPLE_RATE, 1.0)
            ramp = np.arange(1, frames + 1, dtype=np.float32)
            if self._gain < self.target_gain:
                gains = np.minimum(self._gain + fade_step * ramp, self.target_gain)
            else:
                gains = np.maximum(self._gain - fade_step * ramp, self.target_gain)
            self._gain = float(gains[-1])

            rate = self.rate if self.map.varispeed else 1.0
            avail = self._write - self._read - 1
            m = min(frames, int(avail / max(rate, 1e-6)))
            if m <= 0:
                return

            n = len(self._buf)
            pos = self._read + rate * np.arange(m)
            j = pos.astype(np.int64)
            frac = (pos - j).astype(np.float32)[:, None]
            a = self._buf[j % n]
            b = self._buf[(j + 1) % n]
            out[:m] = (a + (b - a) * frac) * gains[:m, None]
            self._read = float(pos[-1]) + rate
