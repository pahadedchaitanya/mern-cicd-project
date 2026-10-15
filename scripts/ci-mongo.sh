#!/usr/bin/env bash
# Start / stop a throw-away MongoDB container for the backend integration tests.
#
#   scripts/ci-mongo.sh start <container-name>   prints  MONGO_TEST_URI=...  as the LAST stdout line
#   scripts/ci-mongo.sh stop  <container-name>
#
# Why this script exists
# ----------------------
# Jenkins itself runs in a container. A test database started with a plain
# "docker run mongo" lands on a *different* Docker network, so Jenkins cannot
# reach it and every backend test fails with "MongooseServerSelectionError".
# This script therefore:
#   1. finds the Docker network Jenkins is attached to (no hard-coded name, so it
#      keeps working if the compose project / folder is renamed) and joins it;
#   2. falls back to the container's bridge IP when Jenkins is not containerised;
#   3. waits until Mongo answers AND is reachable *from Jenkins*, and otherwise
#      fails right here with diagnostics - instead of 9 confusing test failures.
#
# Optional environment:
#   DOCKER_NETWORK  force a specific network name
#   MONGO_IMAGE     image to run            (default mongo:7)
#   WAIT_SECONDS    readiness timeout       (default 90)
set -euo pipefail

ACTION="${1:-}"
NAME="${2:-}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

log() { echo "[ci-mongo] $*" >&2; }   # stderr, so stdout carries only the URI line

usage() {
  echo "usage: $0 start|stop <container-name>" >&2
  exit 2
}

# Name of the first user-defined network this (Jenkins) container is attached to.
# Prints nothing when we are not running inside a container, or only on the default bridge.
jenkins_network() {
  if [ -n "${DOCKER_NETWORK:-}" ]; then
    echo "$DOCKER_NETWORK"
    return 0
  fi
  docker inspect "$(hostname)" \
    --format '{{range $n, $v := .NetworkSettings.Networks}}{{$n}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -vE '^(bridge|host|none)?$' | head -n1 || true
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" = "true" ]
}

fail_with_diagnostics() {
  log "ERROR: $1"
  log "---- docker ps ----";             docker ps --filter "name=$NAME" >&2 || true
  log "---- mongo logs (last 30) ----";  docker logs --tail 30 "$NAME" >&2 || true
  log "---- networks of this host ----"; docker inspect "$(hostname)" \
    --format '{{json .NetworkSettings.Networks}}' >&2 2>/dev/null || log "(not running in a container)"
  log "---- networks of $NAME ----";      docker inspect "$NAME" \
    --format '{{json .NetworkSettings.Networks}}' >&2 2>/dev/null || true
  exit 1
}

start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true

  local net host
  net="$(jenkins_network)"

  if [ -n "$net" ]; then
    log "Joining Docker network '$net' (the network Jenkins is on)"
    docker run -d --name "$NAME" --network "$net" "$MONGO_IMAGE" >/dev/null
    host="$NAME"                                   # Docker DNS resolves the container name
  else
    log "No user-defined Docker network found - using the container's bridge IP"
    docker run -d --name "$NAME" "$MONGO_IMAGE" >/dev/null
    host="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
  fi
  [ -n "$host" ] || fail_with_diagnostics "could not determine an address for $NAME"

  # 1) Mongo answers inside its own container
  local tries=$((WAIT_SECONDS / 2)) i ready=0
  for i in $(seq 1 "$tries"); do
    if docker exec "$NAME" mongosh --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then
      ready=1
      break
    fi
    container_running || fail_with_diagnostics "$NAME stopped unexpectedly"
    log "Waiting for MongoDB to start ($i/$tries)..."
    sleep 2
  done
  [ "$ready" -eq 1 ] || fail_with_diagnostics "MongoDB did not become ready within ${WAIT_SECONDS}s"
  log "MongoDB is ready inside the container"

  # 2) ...and is reachable from where the tests run (this is the check that was missing)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/${host}/27017" 2>/dev/null; then
      log "MongoDB is reachable from Jenkins at ${host}:27017"
      echo "MONGO_TEST_URI=mongodb://${host}:27017/ci_test"
      return 0
    fi
    log "Not reachable from Jenkins yet ($i/10)..."
    sleep 2
  done
  fail_with_diagnostics "MongoDB is running but Jenkins cannot reach ${host}:27017 - Docker network mismatch"
}

stop() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

[ -n "$NAME" ] || usage
case "$ACTION" in
  start) start ;;
  stop)  stop ;;
  *)     usage ;;
esac
