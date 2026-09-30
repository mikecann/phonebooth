#!/usr/bin/env bash
# Install the launcher from this clone. Re-run after moving the clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: bash install.sh [target_bin_dir]"
  echo "Installs the phonebooth launcher (default: ~/.local/bin)."
  echo "Run bash setup_mac.sh to build the app."
  exit 0
fi
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
  echo "Usage: bash install.sh [target_bin_dir]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  TARGET_DIR="$1"
fi

mkdir -p "$TARGET_DIR"
chmod +x "$ROOT/phonebooth"
ln -sf "$ROOT/phonebooth" "$TARGET_DIR/phonebooth"
echo "Installed $TARGET_DIR/phonebooth -> $ROOT/phonebooth"
case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo "Add to ~/.zshrc or ~/.bashrc:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac
echo "Build the app with: bash \"$ROOT/setup_mac.sh\""
echo "Then launch Phonebooth from Spotlight or run: phonebooth"
