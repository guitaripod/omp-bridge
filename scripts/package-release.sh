#!/usr/bin/env bash
#
# Builds the release binary and packs it the way install.sh downloads it:
#
#   dist/omp-bridge-<version>-<os>-<arch>.tar.gz
#   dist/omp-bridge-<version>-<os>-<arch>.tar.gz.sha256
#
# <version> is the newest numbered heading of CHANGELOG.md (an Unreleased section above it does not
# count), the same number the binary reports for --version, and the script refuses to pack a binary
# that reports another one. <os>-<arch> is linux-x86_64, linux-aarch64 or darwin-arm64. The tarball
# holds the binary and the LICENSE, flat.
#
#   scripts/package-release.sh [--out DIR] [--no-build] [--binary FILE --version X.Y.Z]
#
# --no-build packs whatever the build below last produced. --binary packs the given program under
# the given version without building anything: that is how scripts/test-install.sh makes a release
# out of a stand-in, in the very format the real one has. CI builds on the oldest glibc worth
# supporting; see .github/workflows/release.yml.
#
# Linux links the Swift runtime in, so the program needs only the system's C library, libstdc++ and
# libcurl; macOS has the runtime in the system already. The native build system is asked for by name. SwiftPM 6.2 made Swift Build the default, and with
# a 6.4 toolchain on Linux its --static-swift-stdlib link fails on undefined CoreFoundation and ICU
# symbols that the native system resolves.

set -euo pipefail

NAME="omp-bridge"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
BUILD=1
GIVEN_BINARY=""
GIVEN_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --no-build) BUILD=0 ;;
    --binary) GIVEN_BINARY="$2"; BUILD=0; shift ;;
    --version) GIVEN_VERSION="$2"; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

changelog_version() {
  sed -n 's/^## \([0-9][0-9.]*\)\([[:space:]].*\)\{0,1\}$/\1/p' "$ROOT/CHANGELOG.md" | head -1
}

platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  [ "$arch" = "arm64" ] && [ "$os" = "linux" ] && arch="aarch64"
  [ "$arch" = "aarch64" ] && [ "$os" = "darwin" ] && arch="arm64"
  printf '%s-%s' "$os" "$arch"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

VERSION="${GIVEN_VERSION:-$(changelog_version)}"
[ -n "$VERSION" ] || die "no version heading at the head of CHANGELOG.md"
PLATFORM="$(platform)"
ASSET="$NAME-$VERSION-$PLATFORM.tar.gz"

SWIFT_BUILD=(swift build -c release --build-system native)
[ "$(uname -s)" = "Linux" ] && SWIFT_BUILD+=(--static-swift-stdlib)

cd "$ROOT"
if [ "$BUILD" = 1 ]; then
  "${SWIFT_BUILD[@]}"
fi
if [ -n "$GIVEN_BINARY" ]; then
  BINARY="$GIVEN_BINARY"
else
  BINARY="$("${SWIFT_BUILD[@]}" --show-bin-path 2>/dev/null)/$NAME"
fi
[ -x "$BINARY" ] || die "no release binary at $BINARY; build first or drop --no-build"

REPORTED="$("$BINARY" --version)"
[ "$REPORTED" = "$NAME $VERSION" ] ||
  die "the binary says \"$REPORTED\" but CHANGELOG.md says $VERSION; move OmpVersion.fallback"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$BINARY" "$STAGE/$NAME"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
[ "$(uname -s)" = "Darwin" ] || strip "$STAGE/$NAME" 2>/dev/null || true

mkdir -p "$OUT"
rm -f "$OUT/$ASSET" "$OUT/$ASSET.sha256"
COPYFILE_DISABLE=1 tar -czf "$OUT/$ASSET" -C "$STAGE" "$NAME" LICENSE
printf '%s  %s\n' "$(checksum "$OUT/$ASSET")" "$ASSET" >"$OUT/$ASSET.sha256"

CHECK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$CHECK"' EXIT
tar -xzf "$OUT/$ASSET" -C "$CHECK"
[ "$("$CHECK/$NAME" --version)" = "$NAME $VERSION" ] || die "the packed binary does not start"

printf '%s\n%s\n' "$OUT/$ASSET" "$OUT/$ASSET.sha256"
