#!/usr/bin/env bash
# Deploys one commit of this repo to the host, checks it is healthy, and
# rolls back to the last good deploy if it is not.
#
#   scripts/deploy.sh <repo-checkout> <commit> <deploy-dir>
#
# <repo-checkout> is a git clone with full history (the runner's workspace).
# <deploy-dir> is where the stack lives on the host: it holds .env,
# letsencrypt/ and logs/, which are never touched here.
set -euo pipefail

REPO=$(cd "$1" && pwd)
SHA=$(git -C "$REPO" rev-parse --verify "$2^{commit}")
DEPLOY_DIR=$(cd "$3" && pwd)
STATE="$DEPLOY_DIR/.deploy"
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}

log() { printf '==> %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*"; exit 1; }

[[ -f "$DEPLOY_DIR/.env" ]] || fail "$DEPLOY_DIR/.env is missing. Copy .env.example there and fill it in first."
mkdir -p "$STATE" "$DEPLOY_DIR/letsencrypt" "$DEPLOY_DIR/logs"
[[ -f "$DEPLOY_DIR/letsencrypt/acme.json" ]] || touch "$DEPLOY_DIR/letsencrypt/acme.json"
chmod 600 "$DEPLOY_DIR/letsencrypt/acme.json"

env_value() { grep -E "^$1=" "$DEPLOY_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '"'"'"; }
DOMAIN=$(env_value DOMAIN)
AUTHENTIK_DOMAIN=$(env_value AUTHENTIK_DOMAIN)

compose() { docker compose --project-directory "$DEPLOY_DIR" "$@"; }

# Writes the files of a commit into a directory. Tracked files only, so the
# host's .env and certificates are left alone.
extract() { git -C "$REPO" archive "$1" | tar -x -C "$2"; }

# Every service is running (and healthy, where it has a healthcheck), and
# Navidrome and Authentik answer through Traefik.
healthy_once() {
  local want have id state
  want=$(compose config --services | wc -l)
  have=0
  for id in $(compose ps -q); do
    state=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
    case "$state" in
      running/healthy|running/none) have=$((have + 1)) ;;
      *) return 1 ;;
    esac
  done
  [[ "$have" -eq "$want" ]] || return 1
  probe "https://$DOMAIN/rest/ping.view" "$DOMAIN" || return 1
  probe "https://$AUTHENTIK_DOMAIN/-/health/live/" "$AUTHENTIK_DOMAIN" || return 1
}

# -k because a brand-new hostname may not have its certificate yet; this
# checks the service answers, not the certificate.
probe() {
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$2:443:127.0.0.1" "$1" || true)
  [[ "$code" == 2* ]]
}

# Healthy twice, 20 seconds apart, so a container in a crash loop that
# happens to be up at the first look still fails.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while (( SECONDS < deadline )); do
    if healthy_once; then
      sleep 20
      healthy_once && return 0
    fi
    sleep 5
  done
  compose ps -a || true
  compose logs --tail=50 || true
  return 1
}

rollback() {
  local good
  good=$(cat "$STATE/last-good" 2>/dev/null || true)
  if [[ -z "$good" ]]; then
    fail "Deploy of $SHA failed and there is no earlier good deploy to roll back to."
  fi
  log "Rolling back to $good"
  extract "$good" "$DEPLOY_DIR"
  # Put back the exact images that were running before, so a moved tag such
  # as :latest does not bring the new, broken image back with it.
  while read -r ref image_id; do
    docker tag "$image_id" "$ref" || true
  done < "$STATE/previous-images"
  compose up -d --remove-orphans --pull never
  if wait_healthy; then
    echo "$good" > "$STATE/current"
    fail "Deploy of $SHA failed health checks and was rolled back to $good."
  fi
  fail "Deploy of $SHA failed AND the rollback to $good is unhealthy. Check the host."
}

log "Deploying $SHA to $DEPLOY_DIR"

# Check and pull the new version in a scratch directory first, so a bad
# compose file or a missing image changes nothing on the host.
NEW=$(mktemp -d)
trap 'rm -rf "$NEW"' EXIT
extract "$SHA" "$NEW"
docker compose --project-directory "$DEPLOY_DIR" -f "$NEW/docker-compose.yml" config -q \
  || fail "docker-compose.yml at $SHA does not validate against the host's .env. Nothing was changed."
docker compose --project-directory "$DEPLOY_DIR" -f "$NEW/docker-compose.yml" pull \
  || fail "Could not pull the images for $SHA. Nothing was changed."

# Remember what is running now, for the rollback.
: > "$STATE/previous-images"
for id in $(compose ps -q 2>/dev/null || true); do
  docker inspect -f '{{.Config.Image}} {{.Image}}' "$id" >> "$STATE/previous-images"
done

extract "$SHA" "$DEPLOY_DIR"
if compose up -d --remove-orphans --pull never && wait_healthy; then
  echo "$SHA" > "$STATE/last-good"
  echo "$SHA" > "$STATE/current"
  log "Deploy of $SHA is healthy"
else
  rollback
fi
