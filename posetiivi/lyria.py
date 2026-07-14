"""Lyria RealTime -yhteys Gemini API:n kautta (google-genai, v1alpha).

Yhteys on kaksisuuntainen WebSocket: sisään menee prompteja ja
generointiasetuksia, ulos tulee jatkuvaa PCM-audiota (48 kHz s16le stereo).
density/brightness päivittyvät lennossa ilman katkoa; bpm/scale vaatisivat
reset_contextin, joten niitä ei säädetä kammesta.
"""

from __future__ import annotations

import asyncio
import os

from google import genai
from google.genai import types

from .config import LyriaCfg


class LyriaSession:
    def __init__(self, cfg: LyriaCfg, on_audio):
        self.cfg = cfg
        self.on_audio = on_audio  # callback(pcm_bytes)
        self._session = None
        self._playing = False
        self._density: float | None = None
        self._brightness: float | None = None

    async def run(self) -> None:
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            raise RuntimeError("Aseta GEMINI_API_KEY-ympäristömuuttuja.")
        client = genai.Client(
            api_key=api_key, http_options={"api_version": "v1alpha"}
        )
        async with client.aio.live.music.connect(model=self.cfg.model) as session:
            self._session = session
            await session.set_weighted_prompts(
                prompts=[
                    types.WeightedPrompt(text=p.text, weight=p.weight)
                    for p in self.cfg.prompts
                ]
            )
            await session.set_music_generation_config(
                config=self._gen_config()
            )
            print(f"Lyria: yhteys auki ({self.cfg.model})")
            async for message in session.receive():
                content = message.server_content
                if content and content.audio_chunks:
                    for chunk in content.audio_chunks:
                        if chunk.data:
                            self.on_audio(chunk.data)
                await asyncio.sleep(0)

    def _gen_config(self) -> types.LiveMusicGenerationConfig:
        kwargs: dict = {
            "temperature": self.cfg.temperature,
            "guidance": self.cfg.guidance,
        }
        if self.cfg.bpm:
            kwargs["bpm"] = self.cfg.bpm
        if self.cfg.scale:
            kwargs["scale"] = getattr(types.Scale, self.cfg.scale)
        if self._density is not None:
            kwargs["density"] = self._density
        if self._brightness is not None:
            kwargs["brightness"] = self._brightness
        return types.LiveMusicGenerationConfig(**kwargs)

    async def play(self) -> None:
        if self._session and not self._playing:
            await self._session.play()
            self._playing = True

    async def pause(self) -> None:
        if self._session and self._playing:
            await self._session.pause()
            self._playing = False

    async def set_feel(self, density: float, brightness: float) -> None:
        """Päivitä soiton tiheys ja kirkkaus (0..1) lennossa."""
        if not self._session:
            return
        # Kvantisoidaan ettei jokainen pieni kammenheilahdus lähetä pyyntöä.
        density = round(density, 1)
        brightness = round(brightness, 1)
        if density == self._density and brightness == self._brightness:
            return
        self._density, self._brightness = density, brightness
        await self._session.set_music_generation_config(config=self._gen_config())
