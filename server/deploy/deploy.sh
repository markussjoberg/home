#!/bin/sh
# Palvelimen deploy-skripti (/opt/noste/deploy/deploy.sh). GitHub Actions kutsuu
# tätä rajatulla SSH-avaimella (authorized_keys command=), joten avaimella ei voi
# tehdä muuta kuin deployn. Hakee branchin GitHubista, kopioi server/-kansion
# appihakemistoon (data, pgdata ja .env säilyvät) ja rakentaa kontit.
set -eu
REPO=/opt/noste-repo
APP=/opt/noste
BRANCH=$(cat "$APP/deploy-branch" 2>/dev/null || echo "claude/wing-foil-surf-app-pqvliz")
URL=https://github.com/markussjoberg/home.git

if [ ! -d "$REPO/.git" ]; then
  git clone --depth 1 -b "$BRANCH" "$URL" "$REPO"
fi
git -C "$REPO" fetch --depth 1 origin "$BRANCH"
git -C "$REPO" reset -q --hard "origin/$BRANCH"

rsync -a --delete \
  --exclude data --exclude pgdata --exclude .env --exclude node_modules \
  "$REPO/server/" "$APP/"

cd "$APP"
docker compose -f docker-compose.prod.yml up -d --build --quiet-pull 2>&1 | tail -3
sleep 8
docker compose -f docker-compose.prod.yml ps --format '{{.Name}} {{.Status}}'
echo "deploy ok: $(git -C "$REPO" rev-parse --short HEAD) ($BRANCH)"
