#!/usr/bin/env bash
#
# Starts a packed release on a private port and state and sends it a request whose body arrives
# after its headers, the way a phone on a cellular network sends one, then fails unless the bridge
# answered and is still running.
#
#   scripts/smoke-release.sh dist/omp-bridge-<version>-<os>-<arch>.tar.gz
#
# A binary built by Xcode 26.x (Swift 6.3) dies in swift_task_dealloc the moment a handler waits
# for a body that has not arrived yet (swiftlang/swift#84793), which every Mac bridge from 0.11.0
# to 0.12.1 did while the same code built by Swift 6.4 runs fine. Nothing the bridge's own tests
# exercise reads a body from a socket, so the release workflow runs this against what it is about
# to publish.

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

TARBALL="${1:-}"
[ -f "$TARBALL" ] || die "usage: scripts/smoke-release.sh <release tarball>"

WORK="$(mktemp -d)"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/home/.omp-bridge" "$WORK/home/.omp/agent/sessions" "$WORK/work"
tar -xzf "$TARBALL" -C "$WORK/bin"
[ -x "$WORK/bin/omp-bridge" ] || die "no omp-bridge in $TARBALL"

PORT=$((40000 + RANDOM % 20000))
PASSWORD="smoke"
AUTH="$(printf 'omp:%s' "$PASSWORD" | base64 | tr -d '\n')"
BODY="{\"title\":\"smoke\",\"directory\":\"$WORK/work\"}"

env -i PATH=/usr/bin:/bin HOME="$WORK/home" OMP_STATE_DIR="$WORK/home/.omp-bridge" \
  OMP_PORT="$PORT" OMP_BIND=127.0.0.1 OMP_PASSWORD="$PASSWORD" OMP_WORKDIR="$WORK/work" \
  OMP_BIN=/usr/bin/false \
  "$WORK/bin/omp-bridge" >"$WORK/bridge.log" 2>&1 &
PID=$!

alive() { kill -0 "$PID" 2>/dev/null; }

failed() {
  cat "$WORK/bridge.log" >&2
  die "$*"
}

listening() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

for _ in $(seq 1 100); do
  listening && break
  alive || failed "the bridge exited before it listened"
  sleep 0.1
done
listening || failed "the bridge did not listen on port $PORT"

post_late_body() {
  local delay="$1" status=""
  exec 3<>"/dev/tcp/127.0.0.1/$PORT"
  printf 'POST /sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' \
    "$AUTH" "${#BODY}" >&3
  sleep "$delay"
  printf '%s' "$BODY" >&3 2>/dev/null || true
  IFS= read -r -t 10 status <&3 || true
  exec 3<&- 3>&-
  printf '%s' "${status%$'\r'}"
}

for delay in 0 0.5 1; do
  status="$(post_late_body "$delay")" || true
  alive || failed "the bridge died reading a body sent ${delay}s after its headers"
  case "$status" in
    "HTTP/1.1 201"*) ;;
    *) failed "a body sent ${delay}s after its headers was answered \"$status\", not 201" ;;
  esac
  printf 'body after %ss: %s\n' "$delay" "$status"
done
