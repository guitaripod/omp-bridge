#!/usr/bin/env bash

set -euo pipefail

REPO="${OMP_REPO:-}"
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
for argument in "$@"; do
  case "$argument" in
    --update) MODE="update" ;;
    --managed) MANAGED="1" ;;
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

phase() {
  [ "$MODE" = "update" ] || return 0
  printf '{"phase":"%s","startedAt":"%s","pid":%s%s}\n' "$1" "${STARTED_AT:-$(now)}" "$$" \
    "$( [ -n "${2:-}" ] && printf ',"finishedAt":"%s"' "$2" )" >"$STATE_FILE"
}

fail() {
  say "error: $*"
  phase failed "$(now)"
  exit 1
}

STARTED_AT="$(now)"
[ "$MODE" = "update" ] && phase running

need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not installed"; }

need git
if [ -n "${OMP_SWIFT:-}" ] && [ -x "$OMP_SWIFT" ]; then
  PATH="$(dirname "$OMP_SWIFT"):$PATH"
  export PATH
elif ! command -v swift >/dev/null 2>&1; then
  for candidate in "$HOME/.local/share/swiftly/bin" /usr/local/swift/usr/bin /opt/swift/usr/bin; do
    [ -x "$candidate/swift" ] && PATH="$candidate:$PATH" && export PATH && break
  done
fi
need swift

if [ "$MODE" = "install" ]; then
  command -v omp >/dev/null 2>&1 || [ -x /usr/local/bin/omp ] || [ -x "$HOME/.local/bin/omp" ] ||
    say "warning: the omp binary was not found — set OMP_BIN before starting a session"
fi

resolve_repo() {
  if [ -z "$REPO" ] && [ -d "$SRC/.git" ]; then
    REPO="$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || true)"
  fi
}

fetch_source() {
  resolve_repo
  if [ -d "$SRC/.git" ]; then
    say "updating $SRC"
    [ -z "$(git -C "$SRC" status --porcelain)" ] ||
      fail "$SRC has uncommitted changes; commit, stash, or remove them first"
    git -C "$SRC" fetch --quiet --tags origin || fail "could not reach ${REPO:-the remote}"
    local branch
    branch="$(git -C "$SRC" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/master)"
    git -C "$SRC" merge --ff-only "$branch" >>"$LOG" 2>&1 ||
      fail "could not fast-forward to $branch"
  else
    [ -n "$REPO" ] || fail "no checkout at $SRC and OMP_REPO is not set"
    say "cloning $REPO into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet "$REPO" "$SRC" || fail "clone failed"
  fi
}

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

stamp_build() {
  local describe commit
  describe="$( cd "$SRC" && git describe --tags --always --dirty 2>/dev/null || true )"
  commit="$( cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || true )"
  printf '{"version":"%s","commit":"%s","builtAt":"%s","source":"%s"}\n' \
    "${describe:-unknown}" "${commit:-}" "$(now)" "$SRC" >"$STATE_DIR/build.json"
}

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
  local password
  password="${OMP_PASSWORD:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)}"
  mkdir -p "$(dirname "$CONFIG")"
  cat >"$CONFIG" <<EOF
export OMP_PASSWORD="$password"
export OMP_PORT=$PORT
export OMP_BIND=0.0.0.0
export OMP_STATE_DIR=$STATE_DIR
export OMP_SRC=$SRC
EOF
  chmod 600 "$CONFIG"
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
  cat >"$dir/$UNIT" <<EOF
[Unit]
Description=omp-bridge (headless omp agent over HTTP/SSE)
After=network-online.target

[Service]
Type=simple
ExecStart=$BIN
EnvironmentFile=-%h/.config/omp-bridge.env
Environment=OMP_STATE_DIR=$STATE_DIR
Environment=OMP_SRC=$SRC
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  systemctl --user enable --now "$UNIT" >/dev/null 2>&1 || fail "could not start $UNIT"
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

report() {
  local address
  address="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$address" ] || address="$(hostname)"
  cat <<EOF

omp-bridge is running.

  Address   http://$address:$PORT
  Config    $CONFIG
  Binary    $BIN
  Source    $SRC
  Update    re-run this script, or tap Update in Tailscode
EOF
}

if [ "$MODE" = "update" ]; then
  fetch_source
  phase building
  build
  say "built $(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)"
  phase restarting
  if [ -n "$MANAGED" ]; then
    exit 0
  fi
  restart_service
  phase succeeded "$(now)"
  exit 0
fi

fetch_source
build
write_config
if [ "$(uname -s)" = "Darwin" ]; then
  install_service_macos
else
  install_service_linux
fi
sleep 2
report
