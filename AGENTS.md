# Agent guidance for phonebooth

This is a standalone macOS AppKit app and Swift package. All tool sources,
resources and scripts live in this repository.

## Working rules

- Use test-first development for non-trivial changes. Write or update the
  automated test first, then implement until it passes. Extract a test seam if needed.
- When behaviour, UI, layout, persistence or startup changes, update affected
  expectations and rerun the relevant tests after implementation.
- Before committing, run `swift test`, `bash tests/install-tests.sh` and
  `bash -n` on the shell scripts and `phonebooth`. Build the app with
  `bash setup_mac.sh` and check the real app when a change affects it.
- Physical phone checks need a trusted USB-connected iPhone or iPad, Camera
  permission, Developer Mode and Apple developer signing. Unit tests and CI
  must not require devices, permissions, credentials or WebDriverAgent downloads.
- `install.sh` installs only the PATH launcher. `setup_mac.sh` builds the app;
  `restart.sh` stops, rebuilds in debug mode and opens it. Launcher symlinks
  must resolve back to this clone before invoking sibling scripts.
- Keep scripts compatible with macOS Bash 3.2, including empty arrays under `set -u`.
- Preserve `com.mikerosoft.phonebooth` as the app and URL identifier. It is a
  compatibility identifier, not a checkout path; changing it can lose existing
  Camera permissions and preferences. Keep the stable ad-hoc signing requirement.
- Keep signing keys, helper builds, logs and generated app bundles out of Git.
- Write plainly and personally. No em dashes or en dashes in docs. Do not add
  eyebrow or kicker labels to UI designs.
- PR descriptions start with `## Why`, explaining what prompted the change.

## phonebooth specifics

AppKit app that mirrors every USB-connected iPhone or iPad in its own window and
controls it through WebDriverAgent (WDA).

### Dev workflow

```bash
swift test
bash tests/install-tests.sh
bash restart.sh
tail -f ~/Library/Logs/"Phonebooth"/phonebooth.log
```

- `open -g "phonebooth://tap?x=0.5&y=0.5"` (also `swipe?dy=-300`,
  `type?text=hi`, `home`) drives the first phone without clicking. Use it for
  smoke tests.
- Each phone's xcodebuild output goes to
  `~/Library/Logs/Phonebooth/helper-<phone name>.log`. The line
  `ServerURLHere->...<-ServerURLHere` means WDA is up.

### Key behaviour

- Video: setting `kCMIOHardwarePropertyAllowScreenCaptureDevices` makes phones
  appear as `.external` muxed capture devices with model ID `iOS Device`. The same
  phone also appears as a Continuity Camera; the filter skips it.
- Control: `agent.sh` pins WebDriverAgent to a release, clones it into
  `~/Library/Application Support/Phonebooth/WebDriverAgent`, and rewrites the
  runner bundle ID to `com.mikecann.phonebooth.WebDriverAgentRunner`. The stock
  `com.facebook...` ID belongs to another team and can't be signed.
- The team ID comes from `PHONEBOOTH_TEAM_ID`, then `team-id` in the support
  folder, then the OU of the keychain's Apple Development certificate.
- `AgentRunner` runs `agent.sh run`, builds once per launch when the run fails
  with a signing or provisioning error (new phone, expired signing), and
  restarts the helper whenever a command fails.
- The app reaches WDA at `http://[tunnelIPAddress]:8100`, the USB tunnel address
  from `xcrun devicectl list devices`. No usbmux forwarding is needed.
- Touches go through `POST /phonebooth/touch`, a route in
  `wda/PBFastInputCommands.m`. `agent.sh` copies it into
  WDA's `Commands/` folder and `#include`s it from `FBCustomCommands.m`, so the
  Xcode project isn't edited. WDA registers any `FBCommandHandler` class
  automatically. Do not move taps back to `/wda/tap`, `/wda/touchAndHold` or
  `/actions`: they snapshot the app's accessibility tree around every gesture,
  and a single tap took over 3 seconds on an iPhone XS Max.
- `agent.sh build` writes the route file's SHA to
  `DerivedData/phonebooth-routes.sha`. `agent.sh run` exits 3 when it doesn't
  match, which makes `AgentRunner` rebuild. Edit the `.m` file and the next
  launch rebuilds the helper by itself.
- `GET /phonebooth/orientation` returns the raw UIInterfaceOrientation.
  WDA's `/orientation` reports both landscapes as `LANDSCAPE`, which isn't
  enough to place touches. It snapshots the app, so it's only called on connect
  and rotation.
- `POST /phonebooth/nudge` presses and releases Shift. `AgentRunner` sends it
  every 20 seconds while the phone is unlocked (`KeepAwake`), which stops
  auto-lock. Tested on an iPhone XS Max with 30-second Auto-Lock: it stayed
  unlocked through 93 idle seconds, with nothing typed or opened. Never nudge a
  locked phone: it would wake the lock screen.
- The session (used for typing and `window/size`) is created with
  `shouldWaitForQuiescence: false` and `waitForIdleTimeout: 0`.
- A Bluetooth HID approach was tried and dropped. macOS 26 never got a classic
  Bluetooth link to the phone from a third-party app, and the iPhone only accepts
  a mouse through AssistiveTouch.

### Key files

| Path | What it is |
|---|---|
| `Sources/PhoneboothApp/PhoneScreenDevices.swift` | Screen capture opt-in and phone discovery |
| `Sources/PhoneboothApp/MirrorWindowController.swift` | Per-phone window, input handling |
| `Sources/PhoneboothApp/PhoneGestures.swift` | Click/drag/scroll/key to gesture translation (pure) |
| `Sources/PhoneboothApp/PhoneAgent.swift` | WDA HTTP client with an ordered command queue |
| `Sources/PhoneboothApp/AgentRunner.swift` | Builds, starts and restarts WDA per phone |
| `agent.sh` | Fetches, patches, signs, builds and runs WDA |
| `wda/PBFastInputCommands.m` | Fast touch and orientation routes compiled into WDA |

