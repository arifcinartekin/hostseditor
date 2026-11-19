#!/bin/bash
# Hosts Editor installer
#   curl -fsSL https://raw.githubusercontent.com/arifcinartekin/hostseditor/main/install.sh | bash
#
# Downloads the latest prebuilt release (universal: Apple Silicon + Intel) and installs it
# to /Applications (or ~/Applications if /Applications is not writable). If no release can be
# downloaded, it builds from source instead (needs the Xcode Command Line Tools).
set -euo pipefail

REPO="arifcinartekin/hostseditor"
APP_NAME="Hosts Editor.app"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Hosts Editor only runs on macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || die "macOS 14 (Sonoma) or newer is required."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

info "Downloading latest release…"
if curl -fsSL "https://github.com/$REPO/releases/latest/download/HostsEditor.zip" -o "$tmp/app.zip"; then
  ditto -x -k "$tmp/app.zip" "$tmp/out"
else
  info "No release available, building from source…"
  command -v swiftc >/dev/null || die "swiftc not found. Install the Command Line Tools with: xcode-select --install"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp"
  ( cd "$tmp/hostseditor-main" && ARCHS="$(uname -m)" ./build.sh >/dev/null )
  mkdir -p "$tmp/out"
  mv "$tmp/hostseditor-main/build/$APP_NAME" "$tmp/out/"
fi
[[ -d "$tmp/out/$APP_NAME" ]] || die "Download did not contain $APP_NAME."

dest="/Applications"
if [[ ! -w "$dest" ]]; then
  dest="$HOME/Applications"
  mkdir -p "$dest"
fi

pkill -x HostsEditor 2>/dev/null || true
rm -rf "$dest/$APP_NAME"
ditto "$tmp/out/$APP_NAME" "$dest/$APP_NAME"
xattr -dr com.apple.quarantine "$dest/$APP_NAME" 2>/dev/null || true

info "Installed to $dest/$APP_NAME"
open "$dest/$APP_NAME"
