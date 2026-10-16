#!/usr/bin/env bash
#
# omp-bridge installer and updater.
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/omp-bridge/master/install.sh | bash
#
# Downloads the prebuilt release for this machine into ~/.local/bin, writes a config with a
# generated password, and registers a service (systemd --user on Linux, launchd on macOS) so the
# bridge comes back after a reboot. No Swift and no git are needed for that. Only when there is no
# prebuilt release for this machine, the download fails or does not check out, or --from-source is
# given, does it clone the repo into ~/.omp-bridge/src and build it instead.
#
# Re-run it any time to update; --update is the same thing without touching config or service
# files, and is what the bridge runs when a client asks it to update itself. --no-service installs
# everything except the service. A machine that already builds from source keeps doing so.
#
# A client app that already minted a password can pass it through the pipe:
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/omp-bridge/master/install.sh | OMP_REPO=https://github.com/guitaripod/omp-bridge OMP_PASSWORD=xxx bash

# shellcheck disable=SC1090
set -euo pipefail

DEFAULT_REPO="https://github.com/guitaripod/omp-bridge"
REPO="${OMP_REPO:-}"
RELEASE_BASE="${OMP_RELEASE_BASE:-${REPO:-$DEFAULT_REPO}/releases/latest/download}"
RELEASE_BASE="${RELEASE_BASE%/}"
SRC="${OMP_SRC:-$HOME/.omp-bridge/src}"
STATE_DIR="${OMP_STATE_DIR:-$HOME/.omp-bridge}"
CONFIG="$HOME/.config/omp-bridge.env"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/omp-bridge"
LOG="$STATE_DIR/update.log"
STATE_FILE="$STATE_DIR/update.state.json"
LABEL="${OMP_LABEL:-com.omp.bridge}"
UNIT="omp-bridge.service"
PORT="${OMP_PORT:-4099}"
MODE="install"
MANAGED=""
NO_SERVICE=""
FROM_SOURCE=""
for argument in "$@"; do
  case "$argument" in
    --update) MODE="update" ;;
    # The bridge started this update and will restart itself once the build lands, so the script
    # must not touch the service: it is a child of the very thing it would be restarting.
    --managed) MANAGED="1" ;;
    --no-service) NO_SERVICE="1" ;;
    --from-source) FROM_SOURCE="1" ;;
  esac
done

mkdir -p "$STATE_DIR"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

say() {
  if [ "$MODE" = "update" ]; then
    printf '%s\n' "$*" >>"$LOG"
  else
    printf '%s\n' "$*"
  fi
}

# The bridge polls this file to report progress to a client whose server is about to restart under
# it, so every phase change lands here before the work starts. The pid is what makes a second
# installer refusable on liveness rather than on a clock: a cold build on a small machine outlives
# any timeout worth setting, and two builds in one checkout end as a binary nobody can start.
# A failure records the phase it happened in, so the step a client shows as the one that broke is
# the step that broke — a check that refuses in the first second of a build would otherwise be
# blamed on the download the bridge last saw.
#
# A prebuilt install walks the same words: `running` is the download and its checks, `building` is
# putting the verified program in place, `restarting` is the hand-over, exactly as for a build.
CURRENT_PHASE=""
phase() {
  [ "$MODE" = "update" ] || return 0
  [ "$1" = failed ] || CURRENT_PHASE="$1"
  printf '{"phase":"%s","startedAt":"%s","pid":%s%s%s}\n' "$1" "${STARTED_AT:-$(now)}" "$$" \
    "$( [ -n "${2:-}" ] && printf ',"finishedAt":"%s"' "$2" )" \
    "$( [ "$1" = failed ] && [ -n "$CURRENT_PHASE" ] && printf ',"failedIn":"%s"' "$CURRENT_PHASE" )" \
    >"$STATE_FILE"
}

fail() {
  say "error: $*"
  phase failed "$(now)"
  exit 1
}

WORK=""
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

STARTED_AT="$(now)"
[ "$MODE" = "update" ] && phase running

LEFT_ITEMS=""

add_left() { LEFT_ITEMS="$LEFT_ITEMS$*"$'\n'; }

# Runs a command and gives up on it after a number of seconds. Everything the installer asks of
# another program (tailscale, the agent CLI, the freshly downloaded binary) must not be able to hold
# the install hostage, and it still reads this shell's standard input. The kill cannot be argued
# with, because a shell started with SIGTERM ignored passes that on to every child.
bounded() {
  local seconds="$1" pid timer status=0
  shift
  "$@" <&0 &
  pid=$!
  ( sleep "$seconds"; kill -KILL "$pid" ) >/dev/null 2>&1 &
  timer=$!
  wait "$pid" 2>/dev/null || status=$?
  kill -KILL "$timer" >/dev/null 2>&1 || true
  wait "$timer" 2>/dev/null || true
  return "$status"
}

DELIVERY="source"

# Which of the two ways of getting a program this run will try first. A machine that already has a
# checkout keeps building from it: its client compares that checkout with the project to know when
# it is behind, and a prebuilt binary swapped in beside a stale checkout would show an update as
# pending forever.
choose_delivery() {
  if [ -n "$FROM_SOURCE" ]; then
    say "Building from source, as you asked; that takes 5 to 15 minutes and needs Swift and git."
  elif [ -d "$SRC/.git" ]; then
    [ "$MODE" = "update" ] ||
      say "keeping the source build in $SRC — remove that folder to switch to the prebuilt program"
  else
    DELIVERY="binary"
  fi
}

# Falls back to the source build, with the one sentence that says why and what it costs.
fall_back_to_source() {
  DELIVERY="source"
  say "Building from source instead, because $1; that takes 5 to 15 minutes and needs Swift and git."
}

detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) printf 'linux-x86_64' ;;
    Linux-aarch64|Linux-arm64) printf 'linux-aarch64' ;;
    Darwin-arm64) printf 'darwin-arm64' ;;
  esac
}

# One download, quiet, retried on the failures a retry can cure. The exit status tells a missing
# file (22) from a network that is not there.
download() {
  curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 900 \
    -o "$2" "$1" 2>>"$LOG"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads the latest release for this machine and proves it: the checksum matches and the program
# starts here. Leaves the verified program in $WORK/omp-bridge and the version in $VERSION, or
# the reason it could not in $FETCH_REASON.
VERSION=""
FETCH_REASON=""
fetch_release() {
  local platform asset expected status=0
  command -v curl >/dev/null 2>&1 || { FETCH_REASON="curl is not installed"; return 1; }
  platform="$(detect_platform)"
  [ -n "$platform" ] || {
    FETCH_REASON="there is no prebuilt program for $(uname -s) on $(uname -m)"
    return 1
  }
  find "$STATE_DIR" -maxdepth 1 -name '.download.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  WORK="$(mktemp -d "$STATE_DIR/.download.XXXXXX")"

  say "downloading the latest omp-bridge for $platform"
  download "$RELEASE_BASE/latest.txt" "$WORK/latest.txt" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt release has been published yet" ||
      FETCH_REASON="the prebuilt release could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  VERSION="$(tr -d '[:space:]' <"$WORK/latest.txt")"
  case "$VERSION" in
    ''|*[!0-9.]*|.*|*.) FETCH_REASON="the release list at $RELEASE_BASE is not readable"; return 1 ;;
  esac

  asset="omp-bridge-$VERSION-$platform.tar.gz"
  download "$RELEASE_BASE/$asset" "$WORK/$asset" || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 22 ] && FETCH_REASON="no prebuilt program has been published for $platform" ||
      FETCH_REASON="the prebuilt program could not be downloaded from $RELEASE_BASE"
    return 1
  fi
  download "$RELEASE_BASE/$asset.sha256" "$WORK/$asset.sha256" || {
    FETCH_REASON="the prebuilt program came without its checksum"
    return 1
  }
  expected="$(awk 'NR==1 {print $1}' "$WORK/$asset.sha256")"
  [ "$expected" = "$(checksum "$WORK/$asset")" ] || {
    FETCH_REASON="the download did not match its checksum and was thrown away"
    return 1
  }

  tar -xzf "$WORK/$asset" -C "$WORK" omp-bridge 2>>"$LOG" || {
    FETCH_REASON="the download could not be unpacked"
    return 1
  }
  chmod 755 "$WORK/omp-bridge"
  [ "$(bounded 15 "$WORK/omp-bridge" --version </dev/null 2>/dev/null || true)" = "omp-bridge $VERSION" ] || {
    FETCH_REASON="the prebuilt program does not start on this machine"
    return 1
  }
}

# Puts the verified program where the service starts it from. The rename is what keeps a running
# bridge safe: its old file stays whole until it exits, and a crash here leaves the old program.
# The new file is touched because the bridge decides a build is waiting to be loaded by looking at
# the program's modification time, and the archive carries the time it was built, not the time it
# arrived.
install_release() {
  mkdir -p "$BIN_DIR"
  touch "$WORK/omp-bridge"
  mv -f "$WORK/omp-bridge" "$BIN_DIR/.omp-bridge.new"
  mv -f "$BIN_DIR/.omp-bridge.new" "$BIN"
  stamp_release
}

# What the program that was just installed is, in the file the bridge reads once at startup. A
# release has no commit and no checkout, so it names only its version.
stamp_release() {
  printf '{"version":"%s","builtAt":"%s"}\n' "$VERSION" "$(now)" >"$STATE_DIR/build.json"
}

require_toolchain() {
  # OMP_SWIFT is the toolchain the bridge told the client it would build with. Honouring it is what
  # keeps a one-press promise from failing on a PATH the status never saw.
  if [ -n "${OMP_SWIFT:-}" ] && [ -x "$OMP_SWIFT" ]; then
    PATH="$(dirname "$OMP_SWIFT"):$PATH"
    export PATH
  elif ! command -v swift >/dev/null 2>&1; then
    for candidate in "$HOME/.local/share/swiftly/bin" /usr/local/swift/usr/bin /opt/swift/usr/bin; do
      [ -x "$candidate/swift" ] && PATH="$candidate:$PATH" && export PATH && break
    done
  fi
  if ! command -v swift >/dev/null 2>&1; then
    command -v git >/dev/null 2>&1 &&
      fail "building from source needs Swift, which is not installed — get it from https://www.swift.org/install/ and run this again"
    fail "building from source needs Swift and git, which are not installed — get Swift from https://www.swift.org/install/ and git from your package manager, then run this again"
  fi
  command -v git >/dev/null 2>&1 ||
    fail "building from source needs git, which is not installed — install it with your package manager and run this again"
}

resolve_repo() {
  if [ -z "$REPO" ] && [ -d "$SRC/.git" ]; then
    REPO="$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || REPO="$DEFAULT_REPO"
}

fetch_source() {
  resolve_repo
  if [ -d "$SRC/.git" ]; then
    say "updating $SRC"
    [ -z "$(git -C "$SRC" status --porcelain)" ] ||
      fail "$SRC has uncommitted changes; commit, stash, or remove them first"
    git -C "$SRC" fetch --quiet --tags origin || fail "could not reach $REPO"
    local branch
    branch="$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/master)"
    git -C "$SRC" merge --ff-only "$branch" >>"$LOG" 2>&1 ||
      fail "could not fast-forward to $branch"
  else
    say "cloning $REPO into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet "$REPO" "$SRC" || fail "clone failed"
  fi
}

# A build failure reaches a phone as one sentence, so it is worth saying what actually went wrong
# rather than handing over the last twelve lines of a linker's opinion.
build_reason() {
  local tail
  tail="$(tail -c 4000 "$LOG" 2>/dev/null || true)"
  case "$tail" in
    *"No space left on device"*) printf 'the disk on that machine filled up during the build' ;;
    *"Killed"*|*"signal 9"*) printf 'the build was killed — that machine ran out of memory' ;;
    *"module compiled with Swift"*|*"module file format"*)
      printf 'the checkout needs a different Swift than the one installed there' ;;
    *) printf 'build failed — see %s' "$LOG" ;;
  esac
}

# Enough room to build. A disk that fills mid-link reports itself as an unreadable linker error, and
# the number is the one thing that makes it actionable.
check_space() {
  local free
  free="$(df -Pk "$SRC" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
  [ -n "$free" ] || return 0
  [ "$free" -ge 2000000 ] ||
    fail "only $(( free / 1024 )) MB free where the checkout lives; the build needs about 2 GB"
}

build() {
  check_space
  say "building (this takes a few minutes the first time)"
  if ! ( cd "$SRC" && swift build -c release ) >>"$LOG" 2>&1; then
    # A toolchain upgraded under a stale .build produces the same failure forever, and one clean is
    # the difference between an update that heals itself and a machine that never updates again.
    say "build failed; cleaning and trying once more"
    ( cd "$SRC" && swift package clean ) >>"$LOG" 2>&1 || true
    ( cd "$SRC" && swift build -c release ) >>"$LOG" 2>&1 || fail "$(build_reason)"
  fi
  install_binary
  stamp_build
}

install_binary() {
  mkdir -p "$BIN_DIR"
  cp -f "$SRC/.build/release/omp-bridge" "$BIN"
  chmod 755 "$BIN"
}

# What the binary that was just produced was built from.
#
# `git describe` run later answers about the *directory*, which moves when somebody checks out a
# branch and runs ahead of the process for the whole stretch between a build and a restart. The
# bridge reads this file once at startup, so what it reports is a fact about itself.
stamp_build() {
  local describe commit
  describe="$( cd "$SRC" && git describe --tags --always --dirty 2>/dev/null || true )"
  commit="$( cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || true )"
  printf '{"version":"%s","commit":"%s","builtAt":"%s","source":"%s"}\n' \
    "${describe:-unknown}" "${commit:-}" "$(now)" "$SRC" >"$STATE_DIR/build.json"
}

# A client app can mint the password and bake it into the install one-liner
# (`curl … | OMP_PASSWORD=xxx bash`) so both sides carry the same one without anyone retyping it.
# An existing config always wins: rotating a working install's password would lock out every client
# that already has it.
write_config() {
  if [ -f "$CONFIG" ]; then
    if [ -n "${OMP_PASSWORD:-}" ]; then
      local existing
      existing="$(. "$CONFIG" && printf '%s' "${OMP_PASSWORD:-}")"
      [ "$existing" = "$OMP_PASSWORD" ] ||
        say "keeping the password already in $CONFIG — use the one printed below, not the one you passed"
    fi
    return 0
  fi
  local password source_label
  if [ -n "${OMP_PASSWORD:-}" ]; then
    password="$OMP_PASSWORD"
    source_label="the one you passed"
  else
    for env_file in "$HOME/.config/claude-bridge.env" "$HOME/.config/opencode-serve.env"; do
      [ -f "$env_file" ] || continue
      found="$(
        sed -n 's/^\(export \)\?BRIDGE_PASSWORD=\(.*\)$/\2/p' "$env_file" | head -1
      )"
      [ -n "$found" ] || found="$(
        sed -n 's/^\(export \)\?OPENCODE_SERVER_PASSWORD=\(.*\)$/\2/p' "$env_file" | head -1
      )"
      found="$(printf '%s' "$found" | tr -d '"')"
      if [ -n "$found" ]; then
        password="$found"
        source_label="the password $env_file already uses"
        break
      fi
    done
  fi
  if [ -z "${password:-}" ]; then
    password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
    source_label="generated just now — it is in $CONFIG"
  fi
  say "using $source_label as OMP_PASSWORD"
  mkdir -p "$(dirname "$CONFIG")"
  find_omp || true
  {
    printf 'OMP_PASSWORD="%s"\n' "$password"
    printf 'OMP_PORT=%s\n' "$PORT"
    printf 'OMP_BIND=0.0.0.0\n'
    printf 'OMP_STATE_DIR=%s\n' "$STATE_DIR"
    [ "$DELIVERY" = "source" ] && printf 'OMP_SRC=%s\n' "$SRC"
    printf 'OMP_BIN=%s\n' "${OMP_FOUND:-/usr/local/bin/omp}"
  } >"$CONFIG"
  chmod 600 "$CONFIG"
}

# The value a name has in the config, which is what the running bridge will use whatever the
# environment of this run says.
config_value() {
  ( . "$CONFIG" >/dev/null 2>&1 && printf '%s' "${!1:-}" )
}

env_file_lines() {
  [ -f "$CONFIG" ] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)$/\2 \3/p' "$CONFIG"
}

plist_env_block() {
  env_file_lines | while read -r key value; do
    printf '    <key>%s</key>\n    <string>%s</string>\n' "$key" "$value"
  done
}

macos_env_args() {
  if [ ! -f "$CONFIG" ]; then
    return 0
  fi
  printf '<key>EnvironmentVariables</key>\n  <dict>\n'
  plist_env_block
  printf '  </dict>\n'
}

install_service_linux() {
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"
  {
    printf '[Unit]\nDescription=omp-bridge (headless omp agent over HTTP/SSE)\nAfter=network-online.target\n\n'
    printf '[Service]\nType=simple\nExecStart=%s\n' "$BIN"
    printf 'EnvironmentFile=-%%h/.config/omp-bridge.env\n'
    printf 'Environment=OMP_STATE_DIR=%s\n' "$STATE_DIR"
    [ "$DELIVERY" = "source" ] && printf 'Environment=OMP_SRC=%s\n' "$SRC"
    printf 'Restart=always\nRestartSec=3\nTimeoutStopSec=15\n\n'
    printf '[Install]\nWantedBy=default.target\n'
  } >"$dir/$UNIT"
  systemctl --user daemon-reload
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
    say "restarting $UNIT"
    systemctl --user restart "$UNIT" >>"$LOG" 2>&1 || fail "restart failed"
  else
    systemctl --user enable --now "$UNIT" >/dev/null 2>&1 || fail "could not start $UNIT"
  fi
}

install_service_macos() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$LABEL"
    printf '  <key>ProgramArguments</key>\n  <array>\n    <string>%s</string>\n  </array>\n' "$BIN"
    macos_env_args
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '  <key>KeepAlive</key><true/>\n'
    printf '  <key>StandardOutPath</key><string>%s/omp-bridge.log</string>\n' "$STATE_DIR"
    printf '  <key>StandardErrorPath</key><string>%s/omp-bridge.log</string>\n' "$STATE_DIR"
    printf '</dict>\n</plist>\n'
  } >"$plist"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || fail "could not load $LABEL"
}

restart_service() {
  if [ -n "$NO_SERVICE" ]; then
    say "not restarting any service (--no-service)"
    return 0
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    if launchctl list | grep -q "$LABEL"; then
      say "restarting $LABEL"
      launchctl kickstart -k "gui/$(id -u)/$LABEL" >>"$LOG" 2>&1 || fail "restart failed"
      return 0
    fi
  elif systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
    say "restarting $UNIT"
    systemctl --user restart "$UNIT" >>"$LOG" 2>&1 || fail "restart failed"
    return 0
  fi
  say "no service manages this bridge — start it again yourself"
}

TAILSCALE=""
find_tailscale() {
  local candidate
  if [ -n "${OMP_TAILSCALE:-}" ]; then
    [ -x "$OMP_TAILSCALE" ] && { TAILSCALE="$OMP_TAILSCALE"; return 0; }
    return 1
  fi
  for candidate in "$(command -v tailscale 2>/dev/null || true)" \
    /usr/bin/tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { TAILSCALE="$candidate"; return 0; }
  done
  return 1
}

# Tailscale is what lets a phone reach this computer from anywhere. Without it the bridge still
# works on this computer and on the home network, so a missing or signed-out Tailscale is reported
# and the install carries on.
preflight_tailscale() {
  local output="" status=0
  if ! find_tailscale; then
    say "  Tailscale: not installed"
    add_left "Install Tailscale on this computer and on your phone (https://tailscale.com/download) and sign in to both with the same account. Until then the bridge works on this computer and on your home network only."
    return 0
  fi
  output="$(bounded 10 "$TAILSCALE" status 2>&1 </dev/null)" || status=$?
  if [ "$status" -eq 0 ]; then
    say "  Tailscale: connected"
    return 0
  fi
  case "$output" in
    *"Logged out"*|*"NeedsLogin"*|*"Log in at"*)
      say "  Tailscale: installed, but not signed in"
      add_left "Sign in to Tailscale on this computer: run  sudo tailscale up  (or open the Tailscale app) and finish the sign-in. Until then the bridge works on this computer and on your home network only." ;;
    *"stopped"*)
      say "  Tailscale: installed, but turned off"
      add_left "Turn Tailscale on: run  sudo tailscale up  (or switch it on in the Tailscale app). Until then the bridge works on this computer and on your home network only." ;;
    *)
      say "  Tailscale: installed, but not running"
      add_left "Start Tailscale: open the Tailscale app, or on Linux run  sudo systemctl enable --now tailscaled  and then  sudo tailscale up. Until then the bridge works on this computer and on your home network only." ;;
  esac
}

OMP_FOUND=""
find_omp() {
  local candidate
  for candidate in "${OMP_BIN:-}" "$(command -v omp 2>/dev/null || true)" /usr/local/bin/omp \
    "$HOME/.local/bin/omp" "$HOME/.bun/bin/omp"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { OMP_FOUND="$candidate"; return 0; }
  done
  return 1
}

# The bridge is only a doorway: the conversation happens in omp, which has to be on this computer
# and signed in to a model provider. Whether it is comes from omp's own answer to the question the
# bridge asks it; an answer that cannot be read is not reported as signed out.
preflight_agent() {
  local output=""
  if ! find_omp; then
    say "  omp: not installed"
    add_left "Install omp (oh-my-pi, https://github.com/can1357/oh-my-pi) on this computer, sign in to a model provider by running  omp, then put the full path of the omp program as OMP_BIN in $CONFIG and restart the bridge."
    return 0
  fi
  output="$(cd "$HOME" && printf '{"id":"preflight","type":"get_login_providers"}\n' |
    bounded 20 "$OMP_FOUND" --mode rpc 2>/dev/null || true)"
  if printf '%s' "$output" | grep -Eq '"authenticated"[[:space:]]*:[[:space:]]*true'; then
    say "  omp: installed and signed in"
  elif printf '%s' "$output" | grep -Eq '"authenticated"[[:space:]]*:[[:space:]]*false'; then
    say "  omp: installed, but not signed in to any provider"
    add_left "Sign in to a model provider in omp: run  omp  on this computer and follow its sign-in."
  else
    say "  omp: installed (could not check whether it is signed in)"
  fi
}

preflight() {
  say "Checking this computer:"
  preflight_tailscale
  preflight_agent
  say ""
}

# The bridge is up when it answers its own health route with its own password.
wait_for_health() {
  local password attempt=0
  command -v curl >/dev/null 2>&1 || return 0
  password="$(config_value OMP_PASSWORD)"
  while [ "$attempt" -lt "${OMP_HEALTH_ATTEMPTS:-10}" ]; do
    curl -fsS --max-time 2 -u "omp:$password" "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 &&
      return 0
    attempt=$(( attempt + 1 ))
    sleep 1
  done
  return 1
}

print_left() {
  local item number=1
  if [ -z "$LEFT_ITEMS" ]; then
    printf '\nNothing else is left to do on this computer.\n'
    return 0
  fi
  printf '\nWhat is left to do:\n'
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf '  %d. %s\n' "$number" "$item"
    number=$(( number + 1 ))
  done <<EOF
$LEFT_ITEMS
EOF
}

print_address() {
  local address password
  find_tailscale || true
  address="$( [ -n "$TAILSCALE" ] && bounded 10 "$TAILSCALE" ip -4 2>/dev/null </dev/null | head -1 || true)"
  [ -n "$address" ] || address="$(uname -n)"
  password="$(config_value OMP_PASSWORD)"
  cat <<EOF

  Address   http://$address:$PORT
  Username  omp
  Password  $password

Copy this one line into Tailscode's address field — it fills the password too:

  http://$address:$PORT OMP_PASSWORD=$password

Or check it by hand:

  curl -u omp:$password http://$address:$PORT/health
EOF
}

# Runs the binary's own `pair` command, in the environment the service gives it.
run_pair() {
  [ -x "$BIN" ] || return 1
  ( set -a
    [ -f "$CONFIG" ] && . "$CONFIG"
    set +a
    export OMP_STATE_DIR="$STATE_DIR"
    [ "$DELIVERY" = "source" ] && export OMP_SRC="$SRC"
    exec "$BIN" pair )
}

# The pairing link and code when the installed bridge can print them, and the address and password
# the way this script always has when it cannot. `pair` is asked for rather than detected: a
# program that does not know the word exits with a usage error and prints nothing.
print_pairing() {
  local output
  if output="$(bounded 20 run_pair 2>/dev/null </dev/null)" && [ -n "$output" ]; then
    printf '\n%s\n' "$output"
  else
    print_address
  fi
}

report() {
  PORT="$(config_value OMP_PORT)"
  PORT="${PORT:-4099}"
  if [ -n "$NO_SERVICE" ]; then
    printf '\nomp-bridge is installed but not started. Start it with:  %s\n' "$BIN"
  elif wait_for_health; then
    printf '\nomp-bridge is running.\n'
  else
    printf '\nomp-bridge is installed, but it is not answering on port %s yet.\n' "$PORT"
    add_left "Find out why the bridge did not start: $( [ "$(uname -s)" = "Darwin" ] && printf 'read %s/omp-bridge.log' "$STATE_DIR" || printf 'run  journalctl --user -u %s' "$UNIT" )"
  fi
  print_left
  print_pairing
  printf '\nConfig    %s\n' "$CONFIG"
  printf 'Binary    %s\n' "$BIN"
  [ "$DELIVERY" = "source" ] && printf 'Source    %s\n' "$SRC"
  if [ "$DELIVERY" = "source" ]; then
    printf 'Update    re-run this script, or tap Update in Tailscode\n'
  else
    printf 'Update    re-run the install command\n'
  fi
}

choose_delivery

if [ "$MODE" = "update" ]; then
  if [ "$DELIVERY" = "binary" ]; then
    fetch_release || fail "$FETCH_REASON"
    phase building
    install_release
    say "installed omp-bridge $VERSION"
  else
    require_toolchain
    fetch_source
    phase building
    build
    say "built $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
  fi
  phase restarting
  if [ -n "$MANAGED" ]; then
    exit 0
  fi
  restart_service
  phase succeeded "$(now)"
  exit 0
fi

preflight

if [ "$DELIVERY" = "binary" ]; then
  fetch_release || fall_back_to_source "$FETCH_REASON"
fi
if [ "$DELIVERY" = "binary" ]; then
  install_release
  say "installed omp-bridge $VERSION"
else
  require_toolchain
  fetch_source
  build
fi
write_config
if [ -z "$NO_SERVICE" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    install_service_macos
  else
    install_service_linux
  fi
fi
report
