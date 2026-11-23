#!/usr/bin/env bash
# siri-say installer.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/marcomontalbano/siri-say/main/install.sh)"
#
# Environment:
#   SIRI_SAY_PREFIX   directory to install into (default: ~/.local/bin)
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

# Homebrew owns its install: a second copy would shadow it or be shadowed by it.
EXISTING="$(command -v siri-say 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
  case "$(realpath "$EXISTING")" in
    */Cellar/siri-say/*)
      red "siri-say was installed with Homebrew, update it with:"
      red "  brew upgrade siri-say"
      exit 1
      ;;
  esac
fi

# User-level by default: no sudo, and never inside a directory Homebrew manages.
PREFIX="${SIRI_SAY_PREFIX:-$HOME/.local/bin}"
mkdir -p "$PREFIX"

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
