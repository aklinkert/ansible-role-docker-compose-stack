#!/usr/bin/env bash
# Proves that the pull task notifies the restart handler only when needed.
# Needs docker (with compose) and ansible-playbook.
set -euo pipefail
cd "$(dirname "$0")"

port="${REGISTRY_PORT:-5099}"
registry_image="${REGISTRY_IMAGE:-registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373}"
repo="localhost:${port}/compose-stack-test"
TEST_DIR="$(mktemp -d)"
export TEST_DIR REPO="$repo"
stack="$TEST_DIR/stack"
mkdir -p "$stack/build-only"

cleanup() {
  (cd "$stack" && docker compose down --rmi local -v >/dev/null 2>&1) || true
  docker rm -f compose-stack-test-registry >/dev/null 2>&1 || true
  docker rmi "$repo/a" "$repo/b" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

docker run -d --rm --name compose-stack-test-registry -p "127.0.0.1:${port}:5000" "$registry_image" >/dev/null
ready=false
for _ in $(seq 30); do
  if curl -fs "http://localhost:${port}/v2/" >/dev/null; then ready=true; break; fi
  sleep 1
done
$ready || { echo "FAIL: registry not ready after 30s"; exit 1; }

# Two registry services and one service built from source (no image:).
cat > "$TEST_DIR/compose.src.yml" <<YML
services:
  a:
    image: $repo/a
    command: sleep 3600
  b:
    image: $repo/b
    command: sleep 3600
  c:
    build: ./build-only
    command: sleep 3600
YML
cp "$TEST_DIR/compose.src.yml" "$stack/docker-compose.yml"
printf 'FROM busybox:1.36\n' > "$stack/build-only/Dockerfile"

# Pushes an image with new content under the same tag. Locally the tag keeps
# pointing at the previous image, so the next pull is a real update.
push() { # name version
  local old=""
  old="$(docker image inspect --format '{{.Id}}' "$repo/$1" 2>/dev/null || true)"
  printf 'FROM busybox:1.36\nLABEL v=%s\n' "$2" | docker build -q -t "$repo/$1:next" - >/dev/null
  docker tag "$repo/$1:next" "$repo/$1"
  docker push -q "$repo/$1" >/dev/null
  if [ -n "$old" ]; then docker tag "$old" "$repo/$1"; fi
  docker rmi "$repo/$1:next" >/dev/null
}

restarts() { if [ -f "$TEST_DIR/restarts" ]; then wc -l < "$TEST_DIR/restarts" | tr -d ' '; else echo 0; fi; }
fail() { echo "FAIL: $1 (restarts=$(restarts))"; cat "$TEST_DIR/out"; exit 1; }
play() { ansible-playbook "$@" pull.yml >"$TEST_DIR/out" 2>&1 || fail "play failed"; }
expect() { # restarts, description, [changed count]
  [ "$(restarts)" = "$1" ] || fail "$2"
  echo "ok: $2"
}
unchanged() { grep -q 'changed=0' "$TEST_DIR/out" || fail "$1: expected changed=0"; }

push a one; push b one
(cd "$stack" && docker compose pull -q a b && docker compose up -d --build >/dev/null 2>&1)

play; unchanged "running stack, current images"; expect 0 "running stack with current images: changed=0, no notification"
play; unchanged "second run"; expect 0 "second run: changed=0, no notification"

push a two
play; expect 1 "updated image (old one kept locally) notifies once"
[ ! -e "$stack/.restart-pending" ] || fail "marker not cleared after the restart"
play; unchanged "after update"; expect 1 "run after the update: changed=0, no notification"

push b two
if ansible-playbook -e fail_after=true pull.yml >"$TEST_DIR/out" 2>&1; then fail "play should have failed"; fi
[ -e "$stack/.restart-pending" ] || fail "marker missing after a failed play"
expect 1 "failed play: handler did not run"
play; expect 2 "lost notification is recovered on the next run"
play; unchanged "after recovery"; expect 2 "run after recovery: changed=0, no notification"

# A compose file change lost to a failed play is retried.
sed -i.bak 's/sleep 3600/sleep 3601/' "$TEST_DIR/compose.src.yml" && rm "$TEST_DIR/compose.src.yml.bak"
if ansible-playbook -e fail_after=true pull.yml >"$TEST_DIR/out" 2>&1; then fail "play should have failed"; fi
[ -e "$stack/.restart-pending" ] || fail "marker missing after a failed play with a config change"
expect 2 "failed play with config change: handler did not run"
play; expect 3 "lost config change is recovered on the next run"
play; unchanged "after config recovery"; expect 3 "run after config recovery: changed=0, no notification"

(cd "$stack" && docker compose stop >/dev/null 2>&1)
play -e docker_compose_stack_restart_when_stopped=false; expect 3 "stopped stack with restart_when_stopped=false: no notification"
play; expect 4 "stopped stack notifies"

# A broken image CLI must fail the role instead of silently disabling detection.
if ansible-playbook -e docker_compose_image_cli=/nonexistent/docker pull.yml >"$TEST_DIR/out" 2>&1; then fail "broken image CLI should fail the play"; fi
echo "ok: broken image CLI fails the play"

# Check mode must not fail when the stack directory has no compose file yet.
mkdir -p "$TEST_DIR/empty/stack"; cp "$TEST_DIR/compose.src.yml" "$TEST_DIR/empty/"
TEST_DIR="$TEST_DIR/empty" ansible-playbook --check pull.yml >"$TEST_DIR/out" 2>&1 || fail "check mode without compose file"
echo "ok: check mode without compose file"
