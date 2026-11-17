#!/usr/bin/env bash
# Update and run the GemRouter container, with automatic rollback.
#
#   bash ops/docker/deploy.sh                  pull the latest commits, build and switch to them
#   bash ops/docker/deploy.sh rollback         return to the image used before the last deploy
#   bash ops/docker/deploy.sh rollback <tag>   return to a specific build (git short hash)
#   bash ops/docker/deploy.sh restart          recreate the container to reload .env, no build
#   bash ops/docker/deploy.sh status           container state and available builds
#   bash ops/docker/deploy.sh logs             follow the container log
#   bash ops/docker/deploy.sh config           show how Compose reads the configuration
#
# deploy fast-forwards the checkout to its remote branch (never overwriting work
# done by hand on the server), then builds while the running container keeps
# serving. The container is replaced only if the image changed, and the previous
# image comes back automatically when the new one does not answer /health.
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
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

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

# Bring the checkout to the latest commit of the branch it follows.
update_code() {
  if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    log "the current branch follows no remote branch: deploying the checked-out code as is"
    return
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    log "files changed by hand in $(pwd):"
    git status --short --untracked-files=no
    log "not deploying: discard them (git checkout -- .) or commit them first"
    exit 1
  fi
  git fetch --quiet
  if git merge-base --is-ancestor '@{u}' HEAD; then
    log "code already up to date: $(git rev-parse --short HEAD) $(git log -1 --format=%s)"
    return
  fi
  if ! git merge-base --is-ancestor HEAD '@{u}'; then
    log "not deploying: the server checkout has commits that are not on the remote branch"
    exit 1
  fi
  git merge --ff-only --quiet '@{u}'
  log "code updated to $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
}

deploy() {
  update_code

  local rev running_id built_id previous_id
  rev=$(git rev-parse --short HEAD 2>/dev/null || echo manual)
  if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    rev="$rev-dirty"
  fi
  running_id=$(image_id "$IMAGE:current")
  previous_id=$(image_id "$IMAGE:previous")

  log "building $rev (the running container keeps serving)"
  compose build "$SERVICE"
  built_id=$(image_id "$IMAGE:current")
  docker tag "$IMAGE:current" "$IMAGE:$rev"

  if [[ -n "$running_id" && "$built_id" == "$running_id" ]]; then
    log "image unchanged: $rev is already in service"
    compose up -d --no-build "$SERVICE"
    return 0
  fi
  if [[ -n "$running_id" ]]; then
    docker tag "$running_id" "$IMAGE:previous"
  fi

  log "starting the new container"
  compose up -d --no-build --force-recreate "$SERVICE"
  if wait_healthy; then
    log "deploy ok: $rev"
    return 0
  fi

  log "no healthy answer within ${HEALTH_TIMEOUT_S}s; last log lines:"
  docker logs --tail 40 "$CONTAINER" 2>&1 || true
  if [[ -n "$running_id" ]]; then
    log "rolling back to the previous image"
    switch_to "$running_id"
    # Keep the rollback target of before this attempt.
    if [[ -n "$previous_id" ]]; then
      docker tag "$previous_id" "$IMAGE:previous"
    else
      docker image rm "$IMAGE:previous" >/dev/null 2>&1 || true
    fi
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
  local from
  from=$(image_id "$IMAGE:current")
  log "switching to $target"
  switch_to "$target"
  # The version just replaced becomes the rollback target, so a second
  # rollback undoes the first.
  if [[ -n "$from" ]]; then
    docker tag "$from" "$IMAGE:previous"
  fi
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
