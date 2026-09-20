#!/usr/bin/env bash
# siri-say installer.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/marcomontalbano/siri-say/main/install.sh)"
#
# Environment:
#   SIRI_SAY_PREFIX   directory to install into (default: the first writable of
#                     /usr/local/bin, /opt/homebrew/bin, ~/.local/bin)
#   SIRI_SAY_REF      git ref to install from (default: main)
#   SIRI_SAY_URL      full URL of the script, overriding SIRI_SAY_REF

set -euo pipefail

REPO="marcomontalbano/siri-say"
REF="${SIRI_SAY_REF:-main}"
# Note: this must point at the real file. The `siri-say` entry in the repository
# root is a symlink, and GitHub serves a symlink as the text of its target path.
URL="${SIRI_SAY_URL:-https://raw.githubusercontent.com/$REPO/$REF/Sources/siri-say/main.swift}"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { red "siri-say only runs on macOS."; exit 1; }

if ! command -v swift >/dev/null 2>&1; then
  red "swift not found. siri-say runs through the Swift interpreter."
  red "install the Xcode command line tools first:"
  red "  xcode-select --install"
  exit 1
fi

# Pick an install directory: an explicit prefix, else the first writable one.
if [ -n "${SIRI_SAY_PREFIX:-}" ]; then
  PREFIX="$SIRI_SAY_PREFIX"
  mkdir -p "$PREFIX"
else
  PREFIX=""
  for dir in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then PREFIX="$dir"; break; fi
  done
  if [ -z "$PREFIX" ]; then
    PREFIX="$HOME/.local/bin"
    mkdir -p "$PREFIX"
  fi
fi

TARGET="$PREFIX/siri-say"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

bold "Downloading siri-say ($REF)..."
curl -fsSL "$URL" -o "$TMP"
head -1 "$TMP" | grep -q '^#!/usr/bin/env swift' || {
  red "downloaded file is not the siri-say script. check SIRI_SAY_URL/SIRI_SAY_REF"
  exit 1
}

install -m 755 "$TMP" "$TARGET"
bold "Installed $("$TARGET" --version) to $TARGET"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    echo
    red "$PREFIX is not on your PATH. Add it with:"
    red "  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc && exec zsh"
    ;;
esac

cat <<USAGE

Try it:
  siri-say "Hello there"
  siri-say --list            # every voice on this Mac, Siri ones marked [siri]
  siri-say --help

Uninstall:
  rm -f $TARGET
USAGE
