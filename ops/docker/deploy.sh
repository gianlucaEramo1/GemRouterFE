#!/usr/bin/env bash
# Build and run the GemRouter container, with automatic rollback.
#
#   bash ops/docker/deploy.sh                  build the checked-out code and switch to it
#   bash ops/docker/deploy.sh rollback         return to the image used before the last deploy
#   bash ops/docker/deploy.sh rollback <tag>   return to a specific build (git short hash)
#   bash ops/docker/deploy.sh restart          recreate the container to reload .env, no build
#   bash ops/docker/deploy.sh status           container state and available builds
#   bash ops/docker/deploy.sh logs             follow the container log
#   bash ops/docker/deploy.sh config           show how Compose reads the configuration
#
# The running container keeps serving while the new image builds and is only
# replaced when the build succeeds. If the new container does not answer
# /health in time, the previous image is restored automatically.
set -euo pipefail

# Work from the repository root, where .env lives, whatever the caller's directory.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

IMAGE=gemrouter
CONTAINER=gemrouter
SERVICE=gemrouter
HEALTH_TIMEOUT_S=${GEMROUTER_DEPLOY_HEALTH_TIMEOUT_S:-120}

log() { printf '[gemrouter] %s\n' "$*"; }

compose() { docker compose -f ops/docker/docker-compose.yml --env-file .env "$@"; }

require_env() {
  if [[ ! -f .env ]]; then
    log ".env not found in $(pwd): copy .env.example to .env and fill it in (docs/docker.md)"
    exit 1
  fi
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# Ask the app itself rather than Docker's health status, whose 30 s interval
# would slow every deploy down.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_S))
  while (( SECONDS < deadline )); do
    if docker exec "$CONTAINER" node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 4024) + '/health').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

switch_to() {
  docker tag "$1" "$IMAGE:current"
  compose up -d --no-build --force-recreate "$SERVICE"
}

deploy() {
  local rev
  rev=$(git rev-parse --short HEAD 2>/dev/null || echo manual)
  if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    rev="$rev-dirty"
  fi

  if image_exists "$IMAGE:current"; then
    docker tag "$IMAGE:current" "$IMAGE:previous"
  fi

  log "building $rev (the running container keeps serving)"
  compose build "$SERVICE"
  docker tag "$IMAGE:current" "$IMAGE:$rev"

  log "starting the new container"
  compose up -d --no-build --force-recreate "$SERVICE"
  if wait_healthy; then
    log "deploy ok: $rev"
    return 0
  fi

  log "no healthy answer within ${HEALTH_TIMEOUT_S}s; last log lines:"
  docker logs --tail 40 "$CONTAINER" 2>&1 || true
  if image_exists "$IMAGE:previous"; then
    log "rolling back to the previous image"
    switch_to "$IMAGE:previous"
    if wait_healthy; then
      log "rollback ok: the previous version is serving again"
    else
      log "rollback started but the previous version is not healthy either: check 'docker logs $CONTAINER'"
    fi
  fi
  exit 1
}

rollback() {
  local target="$IMAGE:${1:-previous}"
  if ! image_exists "$target"; then
    log "image $target not found; available builds:"
    docker images "$IMAGE" --format '  {{.Tag}}\t{{.CreatedSince}}'
    exit 1
  fi
  log "switching to $target"
  switch_to "$target"
  if wait_healthy; then
    log "rollback ok"
  else
    log "no healthy answer within ${HEALTH_TIMEOUT_S}s: check 'docker logs $CONTAINER'"
    exit 1
  fi
}

restart() {
  log "recreating the container with the current .env"
  compose up -d --no-build --force-recreate "$SERVICE"
  if wait_healthy; then
    log "restart ok"
  else
    log "no healthy answer within ${HEALTH_TIMEOUT_S}s: check 'docker logs $CONTAINER'"
    exit 1
  fi
}

status() {
  compose ps "$SERVICE"
  echo
  echo "Builds (current = running image, previous = rollback target):"
  docker images "$IMAGE" --format '  {{.Tag}}\t{{.ID}}\t{{.CreatedSince}}'
}

command=${1:-deploy}
case "$command" in
  deploy|rollback|restart|status|config) require_env ;;
esac
case "$command" in
  deploy) deploy ;;
  rollback) rollback "${2:-}" ;;
  restart) restart ;;
  status) status ;;
  logs) docker logs -f --tail 100 "$CONTAINER" ;;
  config) compose config ;;
  *)
    echo "usage: $0 [deploy | rollback [tag] | restart | status | logs | config]" >&2
    exit 2
    ;;
esac
