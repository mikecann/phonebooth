#!/usr/bin/env bash
# Builds and starts WebDriverAgent, Apple's UI-testing runner that Phonebooth uses to
# send taps, swipes, and typing to a phone over USB.
#
# Usage:
#   agent.sh build <udid>             fetch WebDriverAgent, sign it with your team, register the phone
#   agent.sh run <udid> <tunnel-ip>   start the helper on the phone (runs until stopped)
#
# The helper has no authentication, so `run` makes it listen only on the phone's USB tunnel
# address (tunnelIPAddress in `xcrun devicectl list devices --json-output -`). Otherwise it
# listens on every interface, and anyone on the phone's Wi-Fi could drive it.
#
# The team ID comes from PHONEBOOTH_TEAM_ID, then "team-id" in the support folder, then the
# Apple Development certificate in your keychain (created by the first successful build).

set -euo pipefail

WDA_VERSION="v16.12.10"
BUNDLE_ID="com.mikecann.phonebooth.WebDriverAgentRunner"
SUPPORT_DIR="${PHONEBOOTH_SUPPORT_DIR:-$HOME/Library/Application Support/Phonebooth}"
WDA_DIR="$SUPPORT_DIR/WebDriverAgent"
DERIVED_DIR="$SUPPORT_DIR/DerivedData"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Phonebooth's fast touch routes, compiled into WebDriverAgent (see the file's header).
FAST_INPUT="$SCRIPT_DIR/wda/PBFastInputCommands.m"
# Records which version of the fast routes and source patches the current build contains.
BUILT_STAMP="$DERIVED_DIR/phonebooth-routes.sha"

usage() {
  echo "Usage: agent.sh build <udid> | agent.sh run <udid> <tunnel-ip>" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
COMMAND="$1"
UDID="$2"

team_id() {
  if [[ -n "${PHONEBOOTH_TEAM_ID:-}" ]]; then
    echo "$PHONEBOOTH_TEAM_ID"
  elif [[ -f "$SUPPORT_DIR/team-id" ]]; then
    tr -d '[:space:]' < "$SUPPORT_DIR/team-id"
  else
    # An Apple Development certificate's organizational unit is the team ID.
    security find-certificate -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' \
      | head -n 1
  fi
}

fetch_source() {
  if [[ "$(git -C "$WDA_DIR" describe --tags 2>/dev/null || true)" != "$WDA_VERSION" ]]; then
    echo "Fetching WebDriverAgent $WDA_VERSION..."
    rm -rf "$WDA_DIR"
    mkdir -p "$SUPPORT_DIR"
    git clone --quiet --depth 1 --branch "$WDA_VERSION" https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
  fi
  # The stock bundle ID belongs to another team, so the runner gets its own.
  sed -i '' "s/com\.facebook\.WebDriverAgentRunner/$BUNDLE_ID/g" "$WDA_DIR/WebDriverAgent.xcodeproj/project.pbxproj"
  # Compile the fast touch routes into WebDriverAgentLib by including them from a file it builds.
  local commands="$WDA_DIR/WebDriverAgentLib/Commands"
  cp "$FAST_INPUT" "$commands/PBFastInputCommands.m"
  if ! grep -q 'PBFastInputCommands.m' "$commands/FBCustomCommands.m"; then
    printf '\n#include "PBFastInputCommands.m"\n' >> "$commands/FBCustomCommands.m"
  fi
  # USE_IP only binds the HTTP server. The MJPEG screenshot stream (port 9100) still listens on
  # every interface, with no authentication. Phonebooth doesn't use it, so keep it on loopback.
  local server="$WDA_DIR/WebDriverAgentLib/Routing/FBWebServer.m"
  local bind_mjpeg='self.screenshotsBroadcaster.interface = @"127.0.0.1";'
  if ! grep -qF "$bind_mjpeg" "$server"; then
    sed -i '' "s/^\( *\)self\.screenshotsBroadcaster\.delegate = self\.mjpegServer;\$/&\\
\\1$bind_mjpeg/" "$server"
  fi
  if ! grep -qF "$bind_mjpeg" "$server"; then
    echo "ERROR: couldn't keep WebDriverAgent's MJPEG stream off the network. Has $server changed?" >&2
    exit 1
  fi
}

# Changes to the fast routes or to how this script patches WebDriverAgent both need a rebuild.
routes_version() {
  cat "$FAST_INPUT" "$SCRIPT_DIR/agent.sh" | shasum | cut -d ' ' -f 1
}

xctestrun_file() {
  ls "$DERIVED_DIR"/Build/Products/*.xctestrun 2>/dev/null | head -n 1 || true
}

case "$COMMAND" in
  build)
    [[ $# -eq 2 ]] || usage
    TEAM="$(team_id)"
    if [[ -z "$TEAM" ]]; then
      echo "ERROR: no Apple developer team found. Sign into Xcode (Settings > Accounts) and put your" >&2
      echo "10-character team ID in \"$SUPPORT_DIR/team-id\", or set PHONEBOOTH_TEAM_ID." >&2
      exit 1
    fi
    # Two phones plugged in together would otherwise build into the same folder at once.
    # A lock older than 15 minutes was left by a killed build and is cleared.
    LOCK="$SUPPORT_DIR/build.lock"
    mkdir -p "$SUPPORT_DIR"
    find "$LOCK" -maxdepth 0 -mmin +15 -exec rmdir {} \; 2>/dev/null || true
    until mkdir "$LOCK" 2>/dev/null; do sleep 2; done
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    fetch_source
    echo "Building WebDriverAgent for $UDID with team $TEAM..."
    xcodebuild build-for-testing \
      -project "$WDA_DIR/WebDriverAgent.xcodeproj" \
      -scheme WebDriverAgentRunner \
      -destination "id=$UDID" \
      -derivedDataPath "$DERIVED_DIR" \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="$TEAM"
    echo "$TEAM" > "$SUPPORT_DIR/team-id"
    routes_version > "$BUILT_STAMP"
    ;;
  run)
    [[ $# -eq 3 ]] || usage
    # An IPv4 or IPv6 literal only, never a hostname or an empty string (which means "every interface").
    [[ "$3" =~ ^[0-9A-Fa-f.:]+$ && "$3" == *[.:]* ]] || usage
    BIND_IP="$3"
    XCTESTRUN="$(xctestrun_file)"
    if [[ -z "$XCTESTRUN" ]]; then
      echo "ERROR: WebDriverAgent isn't built yet. Run: agent.sh build $UDID" >&2
      exit 3
    fi
    if [[ "$(cat "$BUILT_STAMP" 2>/dev/null || true)" != "$(routes_version)" ]]; then
      echo "ERROR: WebDriverAgent was built without the current fast touch routes. Run: agent.sh build $UDID" >&2
      exit 3
    fi
    # xcodebuild passes TEST_RUNNER_ variables to the helper without the prefix, and
    # WebDriverAgent binds its HTTP server to USE_IP.
    export TEST_RUNNER_USE_IP="$BIND_IP"
    exec xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID"
    ;;
  *)
    usage
    ;;
esac
