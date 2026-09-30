#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fake clone lets us verify PATH launchers without opening the app or killing it.
REPO="$WORK/clone with spaces"
BIN="$WORK/bin with spaces"
mkdir -p "$REPO" "$BIN" "$WORK/commands"
cp "$ROOT/phonebooth" "$REPO/phonebooth"
for script in setup_mac restart kill; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$PHONEBOOTH_TEST_LOG"\n' "$script" > "$REPO/$script.sh"
done
cat > "$WORK/commands/open" <<'SH'
#!/usr/bin/env bash
printf 'open: %s\n' "$1" >> "$PHONEBOOTH_TEST_LOG"
SH
chmod +x "$WORK/commands/open"
export PATH="$WORK/commands:$PATH"
export PHONEBOOTH_TEST_LOG="$WORK/events"
export PHONEBOOTH_APP_DIR="$WORK/Phonebooth.app"

# Cover the symlink that the installer creates, including a relative link chain.
ln -s "$REPO/phonebooth" "$BIN/phonebooth"
bash "$BIN/phonebooth" setup
grep -qx setup_mac "$PHONEBOOTH_TEST_LOG"
ln -s phonebooth "$BIN/alias"
bash "$BIN/alias" restart
grep -qx restart "$PHONEBOOTH_TEST_LOG"
bash "$BIN/phonebooth" stop
grep -qx kill "$PHONEBOOTH_TEST_LOG"
bash "$BIN/phonebooth" start
grep -qx "open: $PHONEBOOTH_APP_DIR" "$PHONEBOOTH_TEST_LOG"
if bash "$BIN/phonebooth" unknown 2>/dev/null; then
  echo "Unknown launcher command should fail" >&2
  exit 1
else
  [[ $? -eq 2 ]]
fi

cp "$ROOT/install.sh" "$REPO/install.sh"
rm "$BIN/phonebooth"
bash "$REPO/install.sh" "$BIN"
[[ "$(readlink "$BIN/phonebooth")" == "$REPO/phonebooth" ]]
bash "$REPO/install.sh" "$BIN"
[[ -x "$BIN/phonebooth" ]]
[[ -L "$BIN/alias" ]]
bash "$REPO/install.sh" --help
if bash "$REPO/install.sh" --unknown 2>/dev/null; then
  echo "Unknown installer option should fail" >&2
  exit 1
fi

# A fresh install must tell AgentRunner to build, without contacting a phone.
if PHONEBOOTH_SUPPORT_DIR="$WORK/fresh support" bash "$ROOT/agent.sh" run fake-udid > "$WORK/helper-output" 2>&1; then
  echo "An unbuilt helper should fail" >&2
  exit 1
else
  [[ $? -eq 3 ]]
fi
grep -q "isn't built yet" "$WORK/helper-output"
echo "Installer, launcher and fresh-helper checks passed."
