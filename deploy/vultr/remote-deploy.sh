#!/usr/bin/env bash
# Runs on the Vultr instance, from /opt/drainsense, called by the deploy job in .github/workflows/ci.yml.
#
#   printf '%s\n' "$GHCR_TOKEN" | bash remote-deploy.sh <ghcr-user>
#
# Pulls the images named in .env, starts the stack (Compose project "drainsense"), and waits for the
# API and desk to be healthy. If they are not healthy within two minutes, the previous images
# (.env.previous) are started again and the deploy fails. Then Caddy reloads its config gracefully.
#
#   DRAINSENSE_LOCAL_IMAGES=1   skip the pull (images were loaded with docker load)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ghcr_user="${1:?ghcr user}"
ghcr_token=""
IFS= read -r ghcr_token || true

log() { printf '== %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*"; exit 1; }

command -v docker >/dev/null || fail "Docker is not installed. Run deploy/vultr/bootstrap.sh on the instance first."
docker compose version >/dev/null 2>&1 || fail "The Docker Compose plugin is missing. Run deploy/vultr/bootstrap.sh first."
[[ -f .env ]] || fail "/opt/drainsense/.env is missing; the deploy job writes it."

cleanup() {
  [[ -n "$ghcr_token" ]] && docker logout ghcr.io >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

if [[ "${DRAINSENSE_LOCAL_IMAGES:-0}" == "1" ]]; then
  log "pull skipped (DRAINSENSE_LOCAL_IMAGES=1)"
else
  if [[ -n "$ghcr_token" ]]; then
    printf '%s' "$ghcr_token" | docker login ghcr.io -u "$ghcr_user" --password-stdin >/dev/null
  fi
  log "pull"
  docker compose pull --quiet
fi

healthy() {
  local service="$1" id state
  id="$(docker compose ps -q "$service")"
  [[ -n "$id" ]] || return 1
  state="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo missing)"
  [[ "$state" == "healthy" ]]
}

wait_healthy() {
  for _ in $(seq 1 40); do
    if healthy drainsense-api && healthy drainsense-web; then return 0; fi
    sleep 3
  done
  return 1
}

log "start $(grep -E '^DRAINSENSE_(API|WEB)_IMAGE=' .env | cut -d= -f2 | tr '\n' ' ')"
docker compose up -d --remove-orphans
if ! wait_healthy; then
  docker compose logs --tail 60 drainsense-api drainsense-web || true
  if [[ -f .env.previous ]]; then
    log "not healthy: starting the previous images again"
    cp .env .env.failed
    cp .env.previous .env
    docker compose up -d --remove-orphans
    wait_healthy || true
  fi
  fail "DrainSense containers did not become healthy; see the logs above. The failed image list is in .env.failed."
fi
cp .env .env.previous

# `up -d` recreates Caddy when its environment changed (a new site address). A changed Caddyfile
# alone does not recreate it, so reload. Caddy validates first and keeps the old config on error.
log "reload Caddy"
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
  || fail "Caddy rejected deploy/vultr/caddy/Caddyfile; it is still serving the previous config."

docker image prune -f >/dev/null
docker compose ps
