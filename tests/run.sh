#!/usr/bin/env bash
# Proves that the pull task notifies the restart handler only when an image
# really changed. Needs docker (with compose) and ansible-playbook.
set -euo pipefail
cd "$(dirname "$0")"

port="${REGISTRY_PORT:-5099}"
ref="localhost:${port}/compose-stack-test:latest"
TEST_DIR="$(mktemp -d)"
export TEST_DIR
mkdir -p "$TEST_DIR/stack"
cleanup() { docker rm -f compose-stack-test-registry >/dev/null 2>&1 || true; docker rmi "$ref" >/dev/null 2>&1 || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

docker run -d --rm --name compose-stack-test-registry -p "127.0.0.1:${port}:5000" registry:2 >/dev/null
for _ in $(seq 30); do curl -fs "http://localhost:${port}/v2/" >/dev/null && break; sleep 1; done

printf 'services:\n  app:\n    image: %s\n' "$ref" > "$TEST_DIR/stack/docker-compose.yml"

# Builds an image with a distinct ID per tag content and pushes it to the registry.
push() {
  printf 'FROM scratch\nLABEL v=%s\n' "$1" | docker build -q -t "$ref" - >/dev/null
  docker push -q "$ref" >/dev/null
  docker rmi "$ref" >/dev/null # force the next run to pull from the registry
}

restarts() { [ -f "$TEST_DIR/restarts" ] && wc -l < "$TEST_DIR/restarts" | tr -d ' ' || echo 0; }
play() { ansible-playbook pull.yml 2>&1 | tee "$TEST_DIR/out" | grep -E 'changed=|failed=' ; }
expect() { [ "$(restarts)" = "$1" ] || { echo "FAIL: $2 (restarts=$(restarts), want $1)"; cat "$TEST_DIR/out"; exit 1; }; echo "ok: $2"; }

push one
play; expect 1 "first pull fetches the image and notifies"
play; grep -q 'changed=0' "$TEST_DIR/out"; expect 1 "second run, unchanged image: changed=0, no notification"
play; grep -q 'changed=0' "$TEST_DIR/out"; expect 1 "third run, unchanged image: changed=0, no notification"
push two
play; expect 2 "new image under the same tag notifies once"
play; grep -q 'changed=0' "$TEST_DIR/out"; expect 2 "run after the update: changed=0, no notification"
