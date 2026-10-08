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
if PHONEBOOTH_SUPPORT_DIR="$WORK/fresh support" bash "$ROOT/agent.sh" run fake-udid fd00::1 > "$WORK/helper-output" 2>&1; then
  echo "An unbuilt helper should fail" >&2
  exit 1
else
  [[ $? -eq 3 ]]
fi
grep -q "isn't built yet" "$WORK/helper-output"

# The helper has no authentication, so it must never start without an address to bind to.
for args in "run fake-udid" "run fake-udid not-an-ip" "run fake-udid fd00::1 extra"; do
  # shellcheck disable=SC2086
  if PHONEBOOTH_SUPPORT_DIR="$WORK/fresh support" bash "$ROOT/agent.sh" $args 2>/dev/null; then
    echo "agent.sh $args should be rejected" >&2
    exit 1
  else
    [[ $? -eq 2 ]]
  fi
done

# Build and run against a fake WebDriverAgent checkout and a fake xcodebuild, so this needs
# no network, phone or signing. It checks the source patches and how the helper is started.
SUPPORT="$WORK/agent support"
WDA="$SUPPORT/WebDriverAgent"
# The real xcodebuild creates DerivedData; the fake one doesn't.
mkdir -p "$WDA/WebDriverAgent.xcodeproj" "$WDA/WebDriverAgentLib/Commands" "$WDA/WebDriverAgentLib/Routing" \
  "$SUPPORT/DerivedData/Build/Products"
echo 'PRODUCT_BUNDLE_IDENTIFIER = com.facebook.WebDriverAgentRunner;' > "$WDA/WebDriverAgent.xcodeproj/project.pbxproj"
echo '// custom commands' > "$WDA/WebDriverAgentLib/Commands/FBCustomCommands.m"
cat > "$WDA/WebDriverAgentLib/Routing/FBWebServer.m" <<'OBJC'
- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.mjpegServer = [[FBMjpegServer alloc] init];
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.sharedInstance.mjpegServerPort];
  self.mjpegServer.socket = self.screenshotsBroadcaster;
  self.screenshotsBroadcaster.delegate = self.mjpegServer;
  NSError *error;
OBJC
git -C "$WDA" init -q
git -C "$WDA" add -A
git -C "$WDA" -c user.name=Test -c user.email=test@example.com commit -q -m fake
git -C "$WDA" tag "$(sed -n 's/^WDA_VERSION="\(.*\)"$/\1/p' "$ROOT/agent.sh")"
cat > "$WORK/commands/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf 'xcodebuild %s USE_IP=%s\n' "$1" "${TEST_RUNNER_USE_IP:-}" >> "$PHONEBOOTH_TEST_LOG"
SH
chmod +x "$WORK/commands/xcodebuild"
: > "$PHONEBOOTH_TEST_LOG"
PHONEBOOTH_SUPPORT_DIR="$SUPPORT" PHONEBOOTH_TEAM_ID=ABCDE12345 bash "$ROOT/agent.sh" build fake-udid > /dev/null
PHONEBOOTH_SUPPORT_DIR="$SUPPORT" PHONEBOOTH_TEAM_ID=ABCDE12345 bash "$ROOT/agent.sh" build fake-udid > /dev/null
grep -qx 'xcodebuild build-for-testing USE_IP=' "$PHONEBOOTH_TEST_LOG"
grep -q 'com.mikecann.phonebooth.WebDriverAgentRunner' "$WDA/WebDriverAgent.xcodeproj/project.pbxproj"
[[ "$(grep -c 'PBFastInputCommands.m' "$WDA/WebDriverAgentLib/Commands/FBCustomCommands.m")" -eq 1 ]]
# WebDriverAgent's MJPEG stream ignores USE_IP, so it's patched to stay on the phone's loopback.
[[ "$(grep -c 'screenshotsBroadcaster.interface = @"127.0.0.1";' "$WDA/WebDriverAgentLib/Routing/FBWebServer.m")" -eq 1 ]]

touch "$SUPPORT/DerivedData/Build/Products/fake.xctestrun"
: > "$PHONEBOOTH_TEST_LOG"
PHONEBOOTH_SUPPORT_DIR="$SUPPORT" bash "$ROOT/agent.sh" run fake-udid fde5:3a75:9ac2::1
grep -qx 'xcodebuild test-without-building USE_IP=fde5:3a75:9ac2::1' "$PHONEBOOTH_TEST_LOG"
echo "Installer, launcher and helper checks passed."
