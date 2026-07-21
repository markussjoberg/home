#!/bin/zsh
# Yötreenijono: genrespesialistit hienosäätönä v4-perusmallista.
# Ajo:  caffeinate -is zsh training/train_queue.sh
# Jatkaa seuraavaan vaikka yksi ajo kaatuisi; loki stdouttiin.
set -u
cd "$(dirname "$0")/.."
PY=.venv/bin/python
INIT=training/ckpt/best.pt   # v4-perusmalli (val 0.060)

# genre:stepit — masurkalle vähemmän (582 sävelmää, ylisovitusvara)
for spec in valssi:3000 polkka:3000 marssi:3000 masurkka:2000; do
  g="${spec%%:*}"; steps="${spec##*:}"
  echo "=== [$(date '+%H:%M')] SPESIALISTI: $g ($steps steppiä) ==="
  $PY -u training/train.py \
      --data training/data/prepared_$g --out models/$g \
      --init $INIT --lr 1e-4 --steps $steps --batch 8 \
      || { echo "!!! $g EPÄONNISTUI - jatketaan seuraavaan"; continue; }
  # Demot heti perään (KV-cache -> pari minuuttia)
  beats=3; [ "$g" = polkka ] && beats=2; [ "$g" = marssi ] && beats=4
  for i in 1 2; do
    $PY training/generate.py --ckpt models/$g/best.pt \
        --genre "$g=1.0" --beats $beats --bars 32 --guidance 2.0 \
        --out training/demo/${g}_spec_$i.mid 2>&1 | tail -1
  done
done
echo "=== [$(date '+%H:%M')] JONO VALMIS ==="
