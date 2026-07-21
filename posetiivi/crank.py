"""Kammen (hiiren rullan) luku ja veivausnopeuden estimointi.

Kampi tuottaa evdev REL_WHEEL -tapahtumia. Nopeus estimoidaan liukuvana
keskiarvona pykälistä sekunnissa ja normalisoidaan välille 0..1
(full_speed_ticks_per_sec = 1.0). Pyörityssuunnalla ei ole väliä —
posetiivia saa veivata kumpaan suuntaan haluaa.
"""

from __future__ import annotations

import asyncio
import math
import time

from .config import CrankCfg


class CrankSpeed:
    """Jaettu tila: normalisoitu veivausnopeus 0..1."""

    def __init__(self, cfg: CrankCfg):
        self.cfg = cfg
        self._last_tick = 0.0
        self._ema = 0.0  # pykälää/s, eksponentiaalisesti tasoitettu

    def tick(self, count: int = 1) -> None:
        now = time.monotonic()
        if self._last_tick:
            dt = max(now - self._last_tick, 1e-3)
            inst = count / dt
            alpha = min(dt / 0.25, 1.0)  # ~250 ms aikavakio
            self._ema += alpha * (inst - self._ema)
        self._last_tick = now

    @property
    def normalized(self) -> float:
        if not self._last_tick:
            return 0.0
        idle = time.monotonic() - self._last_tick
        # Ehdoton varakatko kaukana tulevaisuudessa; normaalisti jälkihidastus
        # vie vauhdin kuulumattomiin ennen tätä.
        if idle > self.cfg.stop_timeout_sec:
            return 0.0
        # Vauhtipyörän jälkihidastus: kun veivaus loppuu, vauhti vaimenee
        # eksponentiaalisesti ajasta viime pykälästä sen sijaan että jäätyisi
        # ja hyppäisi nollaan. Kovempi vauhti = pidempi jälkiliuku (enemmän
        # liike-energiaa), kuten oikeassa kammessa. Veivatessa idle ~ 0, joten
        # kerroin ~ 1 eikä vaikuta.
        coasted = self._ema * math.exp(-idle / self.cfg.coast_tau_sec)
        norm = coasted / self.cfg.full_speed_ticks_per_sec
        return norm if norm > 0.02 else 0.0  # kuulumaton -> siisti nollaus

    @property
    def turning(self) -> bool:
        return self.normalized > 0.0


def find_wheel_device(path: str = ""):
    """Palauta evdev-laite jolla on rulla. path ohittaa automaattihaun."""
    import evdev
    from evdev import ecodes

    if path:
        return evdev.InputDevice(path)
    for dev_path in evdev.list_devices():
        dev = evdev.InputDevice(dev_path)
        rel = dev.capabilities().get(ecodes.EV_REL, [])
        if ecodes.REL_WHEEL in rel:
            return dev
        dev.close()
    raise RuntimeError(
        "Rullallista input-laitetta ei löytynyt. Kokeile --list-devices ja "
        "aseta [crank] device config.tomliin, tai lisää käyttäjä input-ryhmään."
    )


def list_devices() -> None:
    import evdev

    for dev_path in evdev.list_devices():
        dev = evdev.InputDevice(dev_path)
        print(f"{dev_path}: {dev.name}")
        dev.close()


async def run_crank(speed: CrankSpeed) -> None:
    """Lue rullatapahtumia ja päivitä nopeusestimaattia."""
    from evdev import ecodes

    dev = find_wheel_device(speed.cfg.device)
    print(f"Kampi: {dev.path} ({dev.name})")
    async for event in dev.async_read_loop():
        if event.type == ecodes.EV_REL and event.code == ecodes.REL_WHEEL:
            speed.tick(abs(event.value))


async def run_pynput_crank(speed: CrankSpeed) -> None:
    """Mac-simulaattori: hiiren/trackpadin scrollaus kampena (pynput).

    Vaatii macOS:n Syötteen valvonta -luvan terminaalille
    (Järjestelmäasetukset > Tietosuoja > Input Monitoring).
    """
    from pynput import mouse

    def on_scroll(_x, _y, _dx, dy):
        if dy:
            speed.tick(abs(int(dy)) or 1)

    listener = mouse.Listener(on_scroll=on_scroll)
    listener.start()
    print("Kampi: hiiren rulla / trackpad-scrollaus (pynput)")
    try:
        while True:
            await asyncio.sleep(1.0)
    finally:
        listener.stop()


async def run_mock_crank(speed: CrankSpeed) -> None:
    """Simuloitu kampi: veivaa aaltoillen, välillä pysähtyen (testaukseen)."""
    print("Kampi: simuloitu (--mock)")
    start = time.monotonic()
    while True:
        # 20 s sykli: ~10 s veivausta kiihtyen/hidastuen, ~10 s tauko.
        t = time.monotonic() - start
        phase = math.sin(2 * math.pi * t / 20.0)
        rate = max(phase, 0.0) * speed.cfg.full_speed_ticks_per_sec
        if rate > 0.5:
            speed.tick()
            await asyncio.sleep(1.0 / rate)
        else:
            await asyncio.sleep(0.1)
