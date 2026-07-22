"""Selainsimulaattori: scrollaus on veivi, liu'ut ovat tulevat GPIO-vivut.

Käynnistys: python -m posetiivi --ui  ->  http://localhost:8737
Pelkkä stdlib (http.server): selain lähettää veivipykälät ja säätimet
JSON-POSTeina, palvelinsäie kirjoittaa suoraan CrankSpeediin,
LiveParamsiin ja syntikkaan — sama rajapinta johon oikeat vivut
kytketään Raspilla.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .midigen import PROGRAM_NAMES, PROGRAMS

# Genret joita nykyinen malli osaa (The Session -treeni). Laajenee kun
# uusi malli treenataan — lista haetaan LiveParams.genre_names:sta jos on.
DEFAULT_GENRES = ["valssi", "polkka", "masurkka", "marssi"]


class WebUI:
    AUTOPLAY_FRACTION = 0.55  # osuus täydestä vauhdista automaattiajossa

    def __init__(self, speed, params, synth, port: int = 8737):
        self.speed = speed
        self.params = params
        self.synth = synth
        self.port = port
        self._autoplay_thread: threading.Thread | None = None
        self._autoplay_stop = threading.Event()
        self._autoplay_lock = threading.Lock()

    def start(self) -> None:
        ui = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):  # hiljennä pyyntöloki
                pass

            def _send(self, code: int, body: bytes, ctype: str) -> None:
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path in ("/", "/index.html"):
                    self._send(200, ui.page().encode(), "text/html; charset=utf-8")
                elif self.path == "/api/state":
                    self._send(200, json.dumps(ui.state()).encode(),
                               "application/json")
                else:
                    self._send(404, b"?", "text/plain")

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                try:
                    msg = json.loads(self.rfile.read(n) or b"{}")
                    ui.apply(msg)
                    self._send(200, b"{}", "application/json")
                except Exception as e:  # säädin ei saa kaataa soitinta
                    self._send(400, str(e).encode(), "text/plain")

        server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"Simulaattori: http://localhost:{self.port}  (scrollaa veiviä!)")

    # --- ohjaus ----------------------------------------------------------

    def apply(self, msg: dict) -> None:
        p = self.params
        if "wheel" in msg:
            self.speed.tick(min(abs(int(msg["wheel"])), 12))
        if "new_tune" in msg:
            p.end_song_request = True
        if "autoplay" in msg:
            self._set_autoplay(bool(msg["autoplay"]))
        if "genre" in msg:
            p.genre_weights = {str(k): max(min(float(v), 1.0), 0.0)
                               for k, v in dict(msg["genre"]).items()}
        if "valence" in msg:
            p.valence = max(min(float(msg["valence"]), 1.0), 0.0)
            p.minor = p.valence < 0.5  # algoritmisäveltäjä lukee tätä
        if "temperature" in msg:
            p.temperature = max(min(float(msg["temperature"]), 1.0), 0.0)
        if "register" in msg:
            p.register = max(min(int(msg["register"]), 2), -1)
        if "program_ix" in msg:
            p.program_ix = int(msg["program_ix"]) % len(PROGRAMS)
        if "accomp_ix" in msg:
            p.accomp_ix = int(msg["accomp_ix"]) % len(PROGRAMS)
        if "vol_mel" in msg:
            self.synth.set_volume(0, int(msg["vol_mel"]))
        if "vol_acc" in msg:
            self.synth.set_volume(1, int(msg["vol_acc"]))
        if "vol_bass" in msg:
            self.synth.set_volume(2, int(msg["vol_bass"]))

    def state(self) -> dict:
        return {"speed": round(self.speed.normalized, 3),
                "params": self.params.describe(),
                "autoplay": self._autoplay_running()}

    # --- autoplay: syöttää tick()-pykäliä samaa reittiä kuin oikea rulla --

    def _autoplay_running(self) -> bool:
        t = self._autoplay_thread
        return t is not None and t.is_alive()

    def _set_autoplay(self, on: bool) -> None:
        with self._autoplay_lock:
            if on and not self._autoplay_running():
                self._autoplay_stop.clear()
                self._autoplay_thread = threading.Thread(
                    target=self._autoplay_loop, daemon=True)
                self._autoplay_thread.start()
            elif not on and self._autoplay_running():
                self._autoplay_stop.set()

    def _autoplay_loop(self) -> None:
        rate = self.AUTOPLAY_FRACTION * self.speed.cfg.full_speed_ticks_per_sec
        interval = 1.0 / max(rate, 1.0)
        while not self._autoplay_stop.wait(interval):
            self.speed.tick(1)

    # --- sivu -------------------------------------------------------------

    def page(self) -> str:
        # Vain genret joilla on treenidataa. V5: genre on VALITSIN (yksi
        # kerrallaan, on/off) — ei sekoitusliukuja. Jatkuvat vivut ovat
        # tunnelmaa, ei genreä.
        genres = list(self.params.data_genres) or DEFAULT_GENRES
        genre_buttons = "\n".join(
            f'<button class="genre{" active" if i == 0 else ""}"'
            f' data-genre="{g}">{g}</button>'
            for i, g in enumerate(genres))
        instr_opts = "".join(f'<option value="{i}">{PROGRAM_NAMES[p]}</option>'
                             for i, p in enumerate(PROGRAMS))
        return PAGE.replace("__GENRES__", genre_buttons).replace(
            "__INSTR__", instr_opts)


PAGE = """<!doctype html><html lang="fi"><head><meta charset="utf-8">
<title>Posetiivi</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: Georgia, serif; background: #2b1d12; color: #f0e2c8;
         margin: 0; display: flex; flex-wrap: wrap; gap: 24px;
         padding: 24px; justify-content: center; }
  h1 { width: 100%; text-align: center; margin: 0 0 8px;
       font-variant: small-caps; letter-spacing: 3px; }
  .panel { background: #3d2b1a; border: 2px solid #8a6a3f; border-radius: 12px;
           padding: 16px 20px; min-width: 260px; }
  .panel h2 { margin: 0 0 10px; font-size: 15px; color: #d9b877;
              font-variant: small-caps; letter-spacing: 2px; }
  #crank { width: 240px; height: 240px; border-radius: 50%;
           border: 10px double #8a6a3f; margin: 8px auto; position: relative;
           background: radial-gradient(#5a4025, #32210f); cursor: grab; }
  #handle { position: absolute; width: 26px; height: 26px; border-radius: 50%;
            background: #d9b877; top: 12px; left: 50%; margin-left: -13px;
            transform-origin: 13px 95px; }
  #speed { text-align: center; font-size: 13px; color: #bfa374; }
  .stop { display: flex; align-items: center; gap: 10px; margin: 7px 0; }
  .stop span { width: 110px; font-size: 14px; }
  input[type=range] { flex: 1; accent-color: #d9b877; }
  select { background: #32210f; color: #f0e2c8; border: 1px solid #8a6a3f;
           border-radius: 6px; padding: 3px 6px; }
  .crank-buttons { display: flex; gap: 8px; justify-content: center;
                   margin-top: 10px; }
  .crank-buttons button { background: #32210f; color: #d9b877;
             border: 1px solid #8a6a3f; border-radius: 8px;
             padding: 6px 14px; font: inherit; font-size: 14px;
             cursor: pointer; }
  .crank-buttons button:active { background: #4a3520; }
  #autoplay.active { background: #d9b877; color: #32210f; }
  #crank.autoplay #handle { animation: spin 2.1s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .hint { font-size: 12px; color: #9b8360; margin-top: 8px; }
  #genres { display: flex; flex-wrap: wrap; gap: 8px; }
  button.genre { background: #32210f; color: #d9b877; border: 1px solid #8a6a3f;
                 border-radius: 8px; padding: 8px 16px; font: inherit;
                 font-size: 15px; cursor: pointer; }
  button.genre.active { background: #d9b877; color: #32210f; font-weight: bold; }
</style></head><body>
<h1>Posetiivi</h1>

<div class="panel">
  <h2>Veivi</h2>
  <div id="crank"><div id="handle"></div></div>
  <div id="speed">scrollaa missä vain — se veivaa</div>
  <div class="crank-buttons">
    <button id="autoplay">▶ Autoplay</button>
    <button id="newtune">■ Uusi kappale</button>
  </div>
</div>

<div class="panel">
  <h2>Tyylilaji</h2>
  <div id="genres">__GENRES__</div>
  <div class="hint">Yksi kerrallaan — vaihto astuu voimaan seuraavan
  kappaleen alussa (tahtilaji vaihtuu genren mukana).</div>
</div>

<div class="panel">
  <h2>Luonne</h2>
  <label class="stop"><span>surullinen ↔ iloinen</span>
    <input type="range" min="0" max="100" value="65" data-param="valence"></label>
  <label class="stop"><span>kesy ↔ villi</span>
    <input type="range" min="0" max="100" value="40" data-param="temperature"></label>
  <label class="stop"><span>rekisteri</span>
    <input type="range" min="-1" max="2" value="0" data-param="register"></label>
</div>

<div class="panel">
  <h2>Raidat</h2>
  <label class="stop"><span>melodia</span>
    <input type="range" min="0" max="127" value="110" data-param="vol_mel"></label>
  <label class="stop"><span>soinnut</span>
    <input type="range" min="0" max="127" value="90" data-param="vol_acc"></label>
  <label class="stop"><span>basso</span>
    <input type="range" min="0" max="127" value="100" data-param="vol_bass"></label>
</div>

<div class="panel">
  <h2>Soundit</h2>
  <label class="stop"><span>melodia</span>
    <select data-sel="program_ix">__INSTR__</select></label>
  <label class="stop"><span>säestys</span>
    <select data-sel="accomp_ix">__INSTR__</select></label>
</div>

<script>
const post = (o) => fetch('/api', {method: 'POST', body: JSON.stringify(o)});

// Veivi: scrollaus missä tahansa sivulla veivaa eteenpäin (suunnasta
// riippumatta); keraantyy ja lahetetaan ~80 ms valein.
let ticks = 0, angle = 0;
const handle = document.getElementById('handle');
window.addEventListener('wheel', (e) => {
  e.preventDefault();
  const n = Math.max(1, Math.round(Math.abs(e.deltaY) / 200));  // 5x vähemmän herkkä
  ticks += n; angle += n * 24;
  handle.style.transform = `rotate(${angle}deg)`;
}, {passive: false});
setInterval(() => { if (ticks) { post({wheel: ticks}); ticks = 0; } }, 80);

// Uusi kappale: malli ajaa nykyisen sävelmän kadenssiin ja aloittaa uuden.
document.getElementById('newtune').addEventListener('click',
  () => post({new_tune: 1}));

// Autoplay: palvelin syöttää tick()-pykäliä samaa reittiä kuin oikea
// rulla, joten muu koneisto ei tiedä eroa. Nappi vain pyytää päälle/pois;
// todellinen tila luetaan aina palvelimelta (toimii usean välilehden yli).
const autoplayBtn = document.getElementById('autoplay');
const crankEl = document.getElementById('crank');
autoplayBtn.addEventListener('click',
  () => post({autoplay: autoplayBtn.dataset.on !== '1'}));

// Tyylilaji: on/off-valinta, yksi kerrallaan (V5). One-hot palvelimelle.
// Genre vaihtuu vasta seuraavan kappaleen alussa (tahtilaji/rekisteri/seed
// riippuvat siitä), joten sama painallus laukaisee myös "uusi kappale"
// -lopetuksen — myös jo aktiivisen genren uudelleenpainallus antaa uuden
// kappaleen samalla genrellä.
const genreBtns = [...document.querySelectorAll('button.genre')];
genreBtns.forEach(el => el.addEventListener('click', () => {
  genreBtns.forEach(b => b.classList.toggle('active', b === el));
  const g = {};
  genreBtns.forEach(b => g[b.dataset.genre] = b === el ? 1 : 0);
  post({genre: g, new_tune: 1});
}));

// Muut saatimet.
document.querySelectorAll('[data-param]').forEach(el =>
  el.addEventListener('input', () => {
    const v = el.dataset.param === 'valence' || el.dataset.param === 'temperature'
              ? el.value / 100 : +el.value;
    post({[el.dataset.param]: v});
  }));
document.querySelectorAll('[data-sel]').forEach(el =>
  el.addEventListener('change', () => post({[el.dataset.sel]: +el.value})));

// Nopeusnaytto + autoplay-tilan synkronointi.
setInterval(async () => {
  const s = await (await fetch('/api/state')).json();
  document.getElementById('speed').textContent =
    s.speed > 0 ? `vauhti ${(s.speed * 100) | 0} %` : 'scrollaa missä vain — se veivaa';
  autoplayBtn.dataset.on = s.autoplay ? '1' : '0';
  autoplayBtn.classList.toggle('active', s.autoplay);
  autoplayBtn.textContent = s.autoplay ? '❚❚ Autoplay käy' : '▶ Autoplay';
  crankEl.classList.toggle('autoplay', s.autoplay);
}, 500);
</script></body></html>"""
