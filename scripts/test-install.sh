#!/usr/bin/env bash
#
# Runs install.sh offline against a fake release served from this machine, with a throwaway HOME
# and a PATH that holds no swift and no git, and checks what a stranger's install would leave
# behind. Nothing here touches the real ~/.omp-bridge, a real service manager or the network:
# systemctl, launchctl and loginctl on the PATH are recording stand-ins.
#
#   scripts/test-install.sh

# shellcheck disable=SC2016,SC2086,SC2206
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PASSED=0
FAILED=0
SERVER_PID=""

cleanup() {
  [ -z "$SERVER_PID" ] || kill -KILL "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { PASSED=$(( PASSED + 1 )); printf 'ok    %s\n' "$1"; }
flunk() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /'; }

check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else flunk "$name"; fi
}

has() { printf '%s' "$1" | grep -Fq -- "$2"; }

expect_has() {
  if has "$1" "$2"; then pass "$3"; else flunk "$3" "wanted: $2
got:
$(printf '%s' "$1" | tail -25)"; fi
}

expect_lacks() {
  if has "$1" "$2"; then flunk "$3" "did not want: $2"; else pass "$3"; fi
}

PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
case "$PLATFORM" in
  linux-x86_64|linux-aarch64|darwin-arm64) ;;
  *) printf 'no prebuilt release exists for %s; nothing to test here\n' "$PLATFORM"; exit 0 ;;
esac

TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for tool in uname date mkdir mktemp curl tar awk sed head tr cut base64 df sha256sum shasum grep \
  cat chmod mv cp rm touch find dirname sleep hostname id tail ls strip stat gzip; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -z "$path" ] || ln -s "$path" "$TOOLS/$tool"
done
BASH_BIN="$(command -v bash)"

check "the test PATH holds neither swift nor git" \
  bash -c "! PATH='$TOOLS' command -v swift && ! PATH='$TOOLS' command -v git"

FAKE="$TMP/fake/omp-bridge"
mkdir -p "$TMP/fake"
cat >"$FAKE" <<'FAKE_EOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "omp-bridge 9.9.9" ;;
  pair)
    echo "$*" >"$OMP_STATE_DIR/pair-args"
    if [ -f "$OMP_STATE_DIR/pair-ok" ]; then echo "PAIRING-LINK tailscode://connect?v=1&fake=1"; exit 0; fi
    echo "unknown command" >&2
    exit 2 ;;
  *) echo "serving" ;;
esac
FAKE_EOF
chmod 755 "$FAKE"
touch -d '2001-01-01' "$FAKE"

WWW="$TMP/www"
mkdir -p "$WWW/good" "$WWW/badsum" "$WWW/noasset" "$WWW/nostart" "$WWW/bare" "$WWW/badscript"
CHANGELOG_FILE="$TMP/CHANGELOG.md"
cat >"$CHANGELOG_FILE" <<'CHANGELOG_EOF'
# Changelog

## Unreleased

- Not released yet.

## 9.9.9 — 2026-10-01

- The newest thing.

## 9.9.8 — 2026-09-01

- The thing before.
CHANGELOG_EOF
"$ROOT/scripts/package-release.sh" --binary "$FAKE" --version 9.9.9 --changelog "$CHANGELOG_FILE" --out "$WWW/good" >"$TMP/package.log" 2>&1
ASSET="omp-bridge-9.9.9-$PLATFORM.tar.gz"
printf '9.9.9\n' >"$WWW/good/latest.txt"
printf 'ok\n' >"$WWW/health"

check "the package script names the archive and its checksum" \
  test -f "$WWW/good/$ASSET" -a -f "$WWW/good/$ASSET.sha256"
check "the archive holds the program, the license and the installer, flat" \
  test "$(tar -tzf "$WWW/good/$ASSET" | LC_ALL=C sort | tr '\n' ' ')" = "LICENSE install.sh omp-bridge "
check "the installer in the archive is this one" \
  bash -c "tar -xzOf '$WWW/good/$ASSET' install.sh | cmp -s - '$ROOT/install.sh'"
check "the changelog asset starts at its own release and drops what is not released" \
  test "$(head -1 "$WWW/good/CHANGELOG-9.9.9.md")" = "## 9.9.9 — 2026-10-01" -a "$(grep -c Unreleased "$WWW/good/CHANGELOG-9.9.9.md")" = 0 -a "$(grep -c '^## ' "$WWW/good/CHANGELOG-9.9.9.md")" = 2
check "the package script refuses a version the changelog does not have" \
  bash -c "! '$ROOT/scripts/package-release.sh' --binary '$FAKE' --version 9.9.7 --changelog '$CHANGELOG_FILE' --out '$TMP/refused' >/dev/null 2>&1"
check "the notes alone can be written without building anything" \
  bash -c "'$ROOT/scripts/package-release.sh' --notes-only --version 9.9.8 --changelog '$CHANGELOG_FILE' --out '$TMP/notes' >/dev/null && test \"\$(head -1 '$TMP/notes/CHANGELOG-9.9.8.md')\" = '## 9.9.8 — 2026-09-01' && test \$(ls '$TMP/notes' | wc -l) -eq 1"
check "the checksum file verifies with sha256sum" \
  bash -c "cd '$WWW/good' && sha256sum -c '$ASSET.sha256' >/dev/null"

cp "$WWW/good/latest.txt" "$WWW/good/$ASSET" "$WWW/badsum/"
printf '%064d  %s\n' 0 "$ASSET" >"$WWW/badsum/$ASSET.sha256"
cp "$WWW/good/latest.txt" "$WWW/noasset/"
BARE="$TMP/bare"
mkdir -p "$BARE"
cp "$FAKE" "$BARE/omp-bridge"
tar -czf "$WWW/bare/$ASSET" -C "$BARE" omp-bridge
printf '%s  %s\n' "$(sha256sum "$WWW/bare/$ASSET" | cut -d' ' -f1)" "$ASSET" >"$WWW/bare/$ASSET.sha256"
cp "$WWW/good/latest.txt" "$WWW/bare/"
BADSCRIPT="$TMP/badscript"
mkdir -p "$BADSCRIPT"
cp "$FAKE" "$BADSCRIPT/omp-bridge"
printf 'if then fi (\n' >"$BADSCRIPT/install.sh"
tar -czf "$WWW/badscript/$ASSET" -C "$BADSCRIPT" omp-bridge install.sh
printf '%s  %s\n' "$(sha256sum "$WWW/badscript/$ASSET" | cut -d' ' -f1)" "$ASSET" >"$WWW/badscript/$ASSET.sha256"
cp "$WWW/good/latest.txt" "$WWW/badscript/"
cp "$WWW/good/latest.txt" "$WWW/nostart/"
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"
printf '#!/bin/sh\nexit 3\n' >"$BROKEN/omp-bridge"
chmod 755 "$BROKEN/omp-bridge"
tar -czf "$WWW/nostart/$ASSET" -C "$BROKEN" omp-bridge
printf '%s  %s\n' "$(sha256sum "$WWW/nostart/$ASSET" | cut -d' ' -f1)" "$ASSET" >"$WWW/nostart/$ASSET.sha256"

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$WWW" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
SERVER_PORT=""
for _ in $(seq 1 50); do
  SERVER_PORT="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$TMP/server.log" | head -1)"
  [ -n "$SERVER_PORT" ] && break
  sleep 0.1
done
[ -n "$SERVER_PORT" ] || { echo "the fake release server did not start"; exit 1; }
SERVER="http://127.0.0.1:$SERVER_PORT"

CLOSED_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

SHIMS=""
HOME_COUNT=0
OUT=""
RC=0
STATE=""
PROGRAM=""
CONF=""
UNIT_FILE=""
HOME_DIR=""
SERVICE_LOG="$TMP/service.log"

fresh_home() {
  HOME_COUNT=$(( HOME_COUNT + 1 ))
  HOME_DIR="$TMP/home$HOME_COUNT"
  STATE="$HOME_DIR/state"
  PROGRAM="$HOME_DIR/.local/bin/omp-bridge"
  CONF="$HOME_DIR/.config/omp-bridge.env"
  UNIT_FILE="$HOME_DIR/.config/systemd/user/omp-bridge.service"
  SHIMS="$TMP/shims$HOME_COUNT"
  mkdir -p "$HOME_DIR" "$SHIMS"
  rm -f "$SERVICE_LOG"
}

shim() {
  printf '#!/bin/sh\n%s\n' "$2" >"$SHIMS/$1"
  chmod 755 "$SHIMS/$1"
}

recording_service_shims() {
  local name
  for name in systemctl loginctl launchctl; do
    shim "$name" "echo \"$name \$*\" >>'$SERVICE_LOG'
case \"\$*\" in *is-active*|*is-enabled*) exit 1;; esac"
  done
}

install() {
  local base="$SERVER/good"
  case "${BASE:-}" in "") ;; *) base="$BASE" ;; esac
  local environment=(env -i HOME="$HOME_DIR" USER=tester PATH="$SHIMS:$TOOLS"
    OMP_STATE_DIR="$STATE" OMP_PORT="${PORT:-$SERVER_PORT}"
    OMP_HEALTH_ATTEMPTS=2 OMP_TAILSCALE="$TMP/no-tailscale" ${ENV_EXTRA:-})
  [ "${BASE:-}" = "-" ] || environment+=(OMP_RELEASE_BASE="$base")
  if [ -n "${PIPED:-}" ]; then
    OUT="$(cat "$ROOT/install.sh" | "${environment[@]}" "$BASH_BIN" -s -- "$@" 2>&1)" && RC=0 || RC=$?
  else
    OUT="$("${environment[@]}" "$BASH_BIN" "$ROOT/install.sh" "$@" 2>&1)" && RC=0 || RC=$?
  fi
}

install_staged() {
  local environment=(env -i HOME="$HOME_DIR" USER=tester PATH="$SHIMS:$TOOLS"
    OMP_STATE_DIR="$STATE" OMP_PORT="${PORT:-$SERVER_PORT}" ${ENV_EXTRA:-})
  OUT="$("${environment[@]}" "$BASH_BIN" "$STATE/staging/install.sh" "$@" 2>&1)" && RC=0 || RC=$?
}

json_field() {
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"
}

phase_words() { sed -n 's/.*"phase":"\([a-z]*\)".*/\1/p' "$1" | tr '\n' ' '; }

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

fresh_home
BASE="" PORT="" ENV_EXTRA="OMP_PASSWORD=sekret123" install --no-service
expect_has "$OUT" "downloading the latest omp-bridge for $PLATFORM" "binary install: says what it is downloading"
check "binary install: succeeds without swift or git" test "$RC" -eq 0
check "binary install: the program lands in ~/.local/bin" test -x "$PROGRAM"
check "binary install: the installed program runs" \
  test "$("$PROGRAM" --version)" = "omp-bridge 9.9.9"
check "binary install: no checkout is made" test ! -e "$HOME_DIR/.omp-bridge/src" -a ! -e "$STATE/src"
check "binary install: the program is stamped as arriving now, not as built in 2001" \
  test "$(( $(date +%s) - $(stat_mtime "$PROGRAM") ))" -lt 300
check "binary install: no download leftovers" test -z "$(find "$STATE" -maxdepth 1 -name '.download.*')"
check "binary install: config holds the injected password" grep -Fxq 'OMP_PASSWORD="sekret123"' "$CONF"
check "binary install: config holds the port, bind and state dir" \
  bash -c "grep -Fxq 'OMP_PORT=$SERVER_PORT' '$CONF' && grep -Fxq 'OMP_BIND=0.0.0.0' '$CONF' && grep -Fxq 'OMP_STATE_DIR=$STATE' '$CONF'"
check "binary install: config names no checkout" bash -c "! grep -q '^OMP_SRC=' '$CONF'"
check "binary install: config names the omp program" grep -q '^OMP_BIN=' "$CONF"
check "binary install: config is private" test "$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF")" = 600
check "binary install: build stamp names the version and a time the bridge can parse" \
  bash -c "test \"\$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[\"version\"])' '$STATE/build.json')\" = 9.9.9 && grep -Eq '\"builtAt\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\"' '$STATE/build.json'"
check "binary install: no phase file outside an update" test ! -e "$STATE/update.state.json"
check "binary install: records that it came from a release, and from where" \
  test "$(json_field "$STATE/install.json" mode)" = release -a "$(json_field "$STATE/install.json" base)" = "$SERVER/good" -a "$(json_field "$STATE/install.json" repo)" = https://github.com/guitaripod/omp-bridge
check "binary install: keeps the installer that came in the archive" \
  bash -c "cmp -s '$STATE/install.sh' '$ROOT/install.sh' && test -x '$STATE/install.sh'"
check "binary install: keeps that installer's checksum beside it" \
  test "$(cut -d' ' -f1 "$STATE/install.sh.sha256")" = "$(sha256sum "$STATE/install.sh" | cut -d' ' -f1)"
check "--no-service: no unit or launch agent is written" test ! -e "$HOME_DIR/.config/systemd" -a ! -e "$HOME_DIR/Library"
check "--no-service: no service manager is called" test ! -s "$SERVICE_LOG"
expect_has "$OUT" "Tailscale: not installed" "pre-flight: reports a missing Tailscale"
expect_has "$OUT" "omp: not installed" "pre-flight: reports a missing omp"
expect_has "$OUT" "What is left to do" "ending: lists what is left"
expect_has "$OUT" "https://tailscale.com/download" "ending: says where to get Tailscale"
expect_has "$OUT" "Then run  $PROGRAM pair  to show the code your phone scans." "ending: says how to get the code once Tailscale is up"
expect_has "$OUT" "installed but not started" "ending: says it did not start a service"
expect_has "$OUT" "Password  sekret123" "ending: prints the password when the program cannot pair"
expect_has "$OUT" "OMP_PASSWORD=sekret123" "ending: prints the one line the app takes"
expect_lacks "$OUT" "Building from source" "binary install: never mentions a source build"

before_listing="$(cd "$HOME_DIR" && find . -type f | sort)"
before_config="$(cksum <"$CONF")"
before_time="$(stat_mtime "$PROGRAM")"
sleep 1
BASE="" PORT="" ENV_EXTRA="" install --no-service
check "re-run: succeeds" test "$RC" -eq 0
check "re-run: leaves the same files behind" test "$(cd "$HOME_DIR" && find . -type f | sort)" = "$before_listing"
check "re-run: keeps the config" test "$(cksum <"$CONF")" = "$before_config"
check "re-run: puts the program in place again" test "$(stat_mtime "$PROGRAM")" -gt "$before_time"
expect_has "$OUT" "Password  sekret123" "re-run: prints the password the config already had"

BASE="" PORT="" ENV_EXTRA="OMP_PASSWORD=other" install --no-service
expect_has "$OUT" "keeping the password already in" "re-run: a different injected password does not rotate the config"
check "re-run: the config still has the first password" grep -Fxq 'OMP_PASSWORD="sekret123"' "$CONF"

touch "$STATE/pair-ok"
BASE="" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "PAIRING-LINK" "pairing: runs the program's own pair command when it has one"
check "pairing: asks for colour only when the person's terminal can show it" \
  test "$(cat "$STATE/pair-args")" = "pair --color never"
expect_lacks "$OUT" "Password  " "pairing: does not print the password block instead"

fresh_home
mkdir -p "$HOME_DIR/.config"
printf 'export BRIDGE_PASSWORD="from-claude"\n' >"$HOME_DIR/.config/claude-bridge.env"
BASE="" PORT="" ENV_EXTRA="" install --no-service
check "no password given: the one claude-bridge already uses is adopted" grep -Fxq 'OMP_PASSWORD="from-claude"' "$CONF"

fresh_home
recording_service_shims
BASE="" PORT="" ENV_EXTRA="" install
if [ "$(uname -s)" = Linux ]; then
  check "service: succeeds" test "$RC" -eq 0
  check "service: writes the unit with the program as its command" \
    grep -Fxq "ExecStart=$PROGRAM" "$UNIT_FILE"
  check "service: the unit reads the config and names the state dir, and no checkout" \
    bash -c "grep -Fxq 'EnvironmentFile=-%h/.config/omp-bridge.env' '$UNIT_FILE' && grep -Fxq 'Environment=OMP_STATE_DIR=$STATE' '$UNIT_FILE' && ! grep -q OMP_SRC '$UNIT_FILE'"
  check "service: enables and starts it as a user service" \
    bash -c "grep -Fxq 'systemctl --user daemon-reload' '$SERVICE_LOG' && grep -Fxq 'systemctl --user enable --now omp-bridge.service' '$SERVICE_LOG'"
  expect_has "$OUT" "omp-bridge is running." "ending: says running once the bridge answers"
fi

fresh_home
recording_service_shims
BASE="" PORT="$CLOSED_PORT" ENV_EXTRA="" install
if [ "$(uname -s)" = Linux ]; then
  expect_has "$OUT" "is installed, but it is not answering on port $CLOSED_PORT" "ending: does not claim a bridge that does not answer is running"
  expect_has "$OUT" "journalctl --user -u omp-bridge.service" "ending: says where to look"
  expect_lacks "$OUT" "omp-bridge is running." "ending: no false running"
fi

fresh_home
shim tailscale 'case "$1" in status) echo "Logged out."; echo "Log in at: https://login.tailscale.com/a/x"; exit 1;; esac'
shim omp 'cat >/dev/null; echo "{\"type\":\"response\",\"success\":true,\"data\":{\"providers\":[{\"id\":\"p\",\"authenticated\":false}]}}"'
BASE="" PORT="" ENV_EXTRA="OMP_BIN=$SHIMS/omp OMP_TAILSCALE=$SHIMS/tailscale" install --no-service
expect_has "$OUT" "Tailscale: installed, but not signed in" "pre-flight: a signed-out Tailscale is named"
expect_has "$OUT" "sudo tailscale up" "pre-flight: and the fix is given"
expect_has "$OUT" "omp: installed, but not signed in to any provider" "pre-flight: an omp with no provider signed in is named"
check "pre-flight: the install carries on regardless" test "$RC" -eq 0 -a -x "$PROGRAM"
check "pre-flight: the config points at the omp that was found" grep -Fxq "OMP_BIN=$SHIMS/omp" "$CONF"

fresh_home
shim tailscale 'case "$1" in status) echo "100.64.0.7 box tester linux -"; exit 0;; ip) echo 100.64.0.7;; esac'
shim omp 'cat >/dev/null; echo "{\"type\":\"response\",\"success\":true,\"data\":{\"providers\":[{\"id\":\"p\",\"authenticated\":true}]}}"'
BASE="" PORT="" ENV_EXTRA="OMP_BIN=$SHIMS/omp OMP_TAILSCALE=$SHIMS/tailscale" install --no-service
expect_has "$OUT" "Tailscale: connected" "pre-flight: a connected Tailscale is named"
expect_has "$OUT" "omp: installed and signed in" "pre-flight: a signed-in omp is named"
expect_has "$OUT" "Nothing else is left to do" "ending: an empty list says so"
expect_has "$OUT" "http://100.64.0.7:$SERVER_PORT" "ending: the address is the tailnet one"

fresh_home
shim omp 'echo "no idea"'
BASE="" PORT="" ENV_EXTRA="OMP_BIN=$SHIMS/omp" install --no-service
expect_has "$OUT" "omp: installed (could not check whether it is signed in)" "pre-flight: an answer that cannot be read is not called signed out"

fresh_home
BASE="$SERVER/badsum" PORT="" ENV_EXTRA="" install --no-service
check "bad checksum: aborts when there is no way to build" test "$RC" -ne 0
expect_has "$OUT" "Building from source instead, because the download did not match its checksum and was thrown away; that takes 5 to 15 minutes" "bad checksum: one sentence says why and how long"
expect_has "$OUT" "https://www.swift.org/install/" "bad checksum: and how to get Swift"
check "bad checksum: nothing was installed" test ! -e "$PROGRAM" -a ! -e "$CONF"

fresh_home
shim git 'if [ "$1" = clone ]; then echo "$*" >>"'"$TMP"'/git.log"; exit 1; fi; exit 0'
shim swift 'exit 0'
rm -f "$TMP/git.log"
BASE="$SERVER/badsum" PORT="" ENV_EXTRA="" install --no-service
check "bad checksum: with a toolchain the source build is what runs" grep -q "clone" "$TMP/git.log"
expect_has "$OUT" "cloning https://github.com/guitaripod/omp-bridge into $HOME_DIR/.omp-bridge/src" "bad checksum: and it clones the project's repo without being told which"

fresh_home
BASE="$SERVER/noasset" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because no prebuilt program has been published for $PLATFORM" "missing asset: falls back and says why"

fresh_home
BASE="$SERVER/nothing-here" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because no prebuilt release has been published yet" "missing release: falls back and says why"

fresh_home
BASE="http://127.0.0.1:$CLOSED_PORT" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because the prebuilt release could not be downloaded" "no network: falls back and says why"

fresh_home
BASE="$SERVER/nostart" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because the prebuilt program does not start on this machine" "a program that will not run here: falls back and says why"
check "a program that will not run here: is not installed" test ! -e "$PROGRAM"

fresh_home
shim uname 'case "$1" in -s) echo Plan9;; -m) echo mips;; *) exec '"$(command -v uname)"' "$@";; esac'
BASE="" PORT="" ENV_EXTRA="" install --no-service
expect_has "$OUT" "because there is no prebuilt program for Plan9 on mips" "unsupported platform: falls back and says why"

fresh_home
BASE="" PORT="" ENV_EXTRA="" install --no-service --from-source
expect_has "$OUT" "Building from source, as you asked; that takes 5 to 15 minutes" "--from-source: says so and how long"
expect_lacks "$OUT" "downloading" "--from-source: downloads nothing"

fresh_home
BASE="" PORT="" ENV_EXTRA="OMP_PASSWORD=sekret123" install --no-service >/dev/null
PHASES="$TMP/phases.log"
rm -f "$PHASES"
real_tar="$(command -v tar)"
real_touch="$(command -v touch)"
shim tar 'cat "'"$STATE"'/update.state.json" >>"'"$PHASES"'"; exec '"$real_tar"' "$@"'
shim touch 'cat "'"$STATE"'/update.state.json" >>"'"$PHASES"'"; exec '"$real_touch"' "$@"'
before_config="$(cksum <"$CONF")"
before_time="$(stat_mtime "$PROGRAM")"
sleep 1
BASE="" PORT="" ENV_EXTRA="" install --update --managed
check "managed update: succeeds" test "$RC" -eq 0
check "managed update: says nothing on stdout" test -z "$OUT"
check "managed update: the phases go running, then building" test "$(phase_words "$PHASES")" = "running building "
check "managed update: ends at restarting and leaves the service alone" test "$(json_field "$STATE/update.state.json" phase)" = restarting -a ! -s "$SERVICE_LOG"
check "managed update: the state file has a start time, the installer's pid and the version it found" \
  bash -c "grep -Eq '^\\{\"phase\":\"restarting\",\"startedAt\":\"[0-9T:Z-]+\",\"pid\":[0-9]+,\"target\":\"9.9.9\"\\}\$' '$STATE/update.state.json'"
check "managed update: the log says what happened" bash -c "grep -Fq 'downloading the latest omp-bridge' '$STATE/update.log' && grep -Fq 'installed omp-bridge 9.9.9' '$STATE/update.log'"
check "managed update: the config is untouched" test "$(cksum <"$CONF")" = "$before_config"
check "managed update: the new program is stamped as newer than the old" test "$(stat_mtime "$PROGRAM")" -gt "$before_time"

BASE="" PORT="" ENV_EXTRA="" install --update
check "unmanaged update: succeeds and ends at succeeded with a finish time" \
  test "$RC" -eq 0 -a "$(json_field "$STATE/update.state.json" phase)" = succeeded -a -n "$(json_field "$STATE/update.state.json" finishedAt)"

before_binary="$(cksum <"$PROGRAM")"
BASE="$SERVER/badsum" PORT="" ENV_EXTRA="" install --update --managed
check "failed update: exits non-zero" test "$RC" -ne 0
check "failed update: records failed, and the phase it failed in" \
  test "$(json_field "$STATE/update.state.json" phase)" = failed -a "$(json_field "$STATE/update.state.json" failedIn)" = running -a -n "$(json_field "$STATE/update.state.json" finishedAt)"
check "failed update: the last log line is a sentence for a person" \
  test "$(grep '^error: ' "$STATE/update.log" | tail -1)" = "error: the download did not match its checksum and was thrown away"
check "failed update: the installed program is untouched" test "$(cksum <"$PROGRAM")" = "$before_binary"

fresh_home
BASE="" PORT="" ENV_EXTRA="OMP_PASSWORD=sekret123" install --no-service >/dev/null
mkdir -p "$STATE/staging"
cp "$STATE/install.sh" "$STATE/staging/install.sh"
before_time="$(stat_mtime "$PROGRAM")"
sleep 1
BASE="-" PORT="" ENV_EXTRA="" install_staged --update --managed
check "update by the kept installer, with no base given: finds the release where the record says" \
  test "$RC" -eq 0 -a "$(json_field "$STATE/update.state.json" phase)" = restarting -a "$(json_field "$STATE/update.state.json" target)" = 9.9.9
check "update by the kept installer: the program is put in place again" test "$(stat_mtime "$PROGRAM")" -gt "$before_time"
check "update by the kept installer: the record and the installer stay" \
  test "$(json_field "$STATE/install.json" mode)" = release -a "$(json_field "$STATE/install.json" base)" = "$SERVER/good" -a -x "$STATE/install.sh"

printf 'rotted\n' >"$STATE/install.sh"
BASE="$SERVER/bare" PORT="" ENV_EXTRA="" install --update --managed
check "an archive without an installer still updates" test "$RC" -eq 0 -a "$(json_field "$STATE/update.state.json" phase)" = restarting
check "an archive without an installer says so and leaves the kept one alone" \
  bash -c "grep -Fq 'this release carries no installer' '$STATE/update.log' && test \"\$(cat '$STATE/install.sh')\" = rotted"

fresh_home
BASE="" PORT="" ENV_EXTRA="" install --no-service >/dev/null
before_binary="$(cksum <"$PROGRAM")"
before_installer="$(cksum <"$STATE/install.sh")"
BASE="$SERVER/badscript" PORT="" ENV_EXTRA="" install --update --managed
check "an installer that is not a script is refused before anything is replaced" \
  test "$RC" -ne 0 -a "$(json_field "$STATE/update.state.json" phase)" = failed -a "$(cksum <"$PROGRAM")" = "$before_binary" -a "$(cksum <"$STATE/install.sh")" = "$before_installer"
check "an installer that is not a script: the reason is a sentence for a person" \
  test "$(grep '^error: ' "$STATE/update.log" | tail -1)" = "error: the installer in this release does not read as a script"

fresh_home
BASE="" PORT="" ENV_EXTRA="" install --no-service >/dev/null
BASE="$SERVER/badsum" PORT="" ENV_EXTRA="" install --update --managed
check "a checksum failure on a release install: the old program, installer and record are as they were" \
  test "$RC" -ne 0 -a "$("$PROGRAM" --version)" = "omp-bridge 9.9.9" -a "$(json_field "$STATE/install.json" mode)" = release

fresh_home
mkdir -p "$STATE/src/.git"
shim git 'case "$1 $2" in "-C "*) shift 2;; esac; case "$1" in status) exit 0;; fetch) exit 1;; esac; exit 0'
shim swift 'exit 0'
BASE="http://127.0.0.1:$CLOSED_PORT" PORT="" ENV_EXTRA="OMP_SRC=$STATE/src" install --update --managed
check "update of a source install stays a source update: no download is tried" \
  bash -c "! grep -Fq downloading '$STATE/update.log' && grep -Fq 'error: could not reach' '$STATE/update.log'"

fresh_home
shim tailscale 'cat >/dev/null; case "$1" in status) exit 0;; ip) echo 100.64.0.9;; esac'
shim omp 'cat >/dev/null; echo "{\"type\":\"response\",\"success\":true,\"data\":{\"providers\":[{\"id\":\"p\",\"authenticated\":true}]}}"'
PIPED=1 BASE="" PORT="" ENV_EXTRA="OMP_PASSWORD=sekret123 OMP_BIN=$SHIMS/omp OMP_TAILSCALE=$SHIMS/tailscale" install --no-service
check "piped through bash like the one-liner: tools that read stdin cannot eat the script" test "$RC" -eq 0 -a -x "$PROGRAM"
expect_has "$OUT" "http://100.64.0.9:$SERVER_PORT OMP_PASSWORD=sekret123" "piped through bash like the one-liner: reaches the ending"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
