#!/usr/bin/env bash
set -euo pipefail

PORT="${SMOKE_PORT:-4099}"
PASSWORD="smoke-$(date +%s)"
WORKDIR="$(mktemp -d)"
LOG="$WORKDIR/bridge.log"
BIN=".build/release/omp-bridge"

command -v omp >/dev/null || { echo "omp is not on the PATH" >&2; exit 1; }
[ -x "$BIN" ] || swift build -c release

setsid env OMP_PASSWORD="$PASSWORD" OMP_PORT="$PORT" OMP_BIND=127.0.0.1 OMP_BIN="$(command -v omp)" \
  OMP_WORKDIR="$WORKDIR" OMP_STATE_DIR="$WORKDIR/state" "$BIN" </dev/null >"$LOG" 2>&1 &
BRIDGE_PID=$!
trap 'kill "$BRIDGE_PID" 2>/dev/null || true' EXIT
sleep 2

auth=(-u "omp:$PASSWORD")
base="http://127.0.0.1:$PORT"

curl -s "${auth[@]}" "$base/status"
echo
SID="$(curl -s "${auth[@]}" -X POST "$base/sessions" \
  -H 'Content-Type: application/json' -d "{\"directory\":\"$WORKDIR\"}" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "session: $SID"

(curl -s -N "${auth[@]}" "$base/sessions/$SID/events" >"$WORKDIR/events.sse" &)
sleep 1
curl -s "${auth[@]}" -X POST "$base/sessions/$SID/message" \
  -H 'Content-Type: application/json' -d '{"text":"Reply with just the word hello, nothing else."}'
echo
sleep 25

python3 - "$SID" "$WORKDIR/events.sse" <<'PY'
import json, sys
sid, sse = sys.argv[1], sys.argv[2]
summary = json.loads(sys.stdin.read()) if False else None
frames = [json.loads(line[6:]) for line in open(sse) if line.startswith("data: ")]
kinds = [f.get("type") for f in frames]
assert "delta" in kinds, f"no streaming deltas; got {kinds}"
assert "running" in kinds and "idle" in kinds, f"no status lifecycle; got {kinds}"
print(f"sse ok: {len(frames)} frames")
PY
echo "smoke passed"
