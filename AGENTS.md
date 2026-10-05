# AGENTS.md — m5-system-panel

## Summary

An M5Stack BASIC v2.7 shows one Mac's CPU, GPU, memory and network. Two parts in
one repository:

- **Companion** — a macOS menu bar app (Swift 6, SwiftUI `MenuBarExtra`, menu
  style; macOS 26+, Apple Silicon). Measures, finds the panel over Bonjour,
  connects over TCP, sends one frame per second, and performs the panel's
  initial setup.
- **Firmware** — Arduino C++ with M5Unified on the `esp32:esp32` core. Draws the
  frames it receives; buttons A/C/B switch pages. Nothing is sent to the Mac
  except acknowledgements.

Transport is Wi-Fi. A key is shared at setup inside the panel's temporary
SoftAP; every frame in both directions is encrypted and authenticated with it
(AES-256-GCM with per-session keys from HKDF-SHA256 Expand;
ChaCha20-Poly1305 is not built into the panel's libraries — ADR-0002). The
wire format is [protocol v2](docs/ja/protocol.ja.md) ([en](docs/en/protocol.md)); v2 adds the
brightness level `bri` to the measurements, and the companion still speaks v1 to old panels (§10).

**Current state: v0.1.1 released; brightness (protocol v2, ADR-0003) unreleased.**
Setup, the encrypted run session, the five pages and the brightness levels
work end to end on a BASIC v2.7 with macOS 27 (end-to-end findings in
`spikes/README.md`). Phase 0 measurements: `spikes/README.md`; decisions:
ADR-0001, ADR-0002, ADR-0003; wire format: docs/{ja,en}/protocol.

## Build & test

```bash
make test             # swift test — also checks the constants shared with the firmware
make build            # companion release binary (.build/release)
make build-app        # dist/M5SystemPanel.app, signed (Developer ID)
make package          # + notarize, staple, zip (release only)
make firmware         # dist/firmware/m5-system-panel.ino.bin (pinned core/libs)
make firmware-upload PORT=/dev/cu.usbserial-XXXX   # flash at 230400 baud
make firmware-package   # dist/m5-system-panel-firmware-<ver>-m5stack-basic.zip
make verify-release     # marker, staple, spctl, SDK, firmware archive and its version
make brew               # cask into the local homebrew-tap checkout (after make package)
make protocol-test    # vectors.h from testdata + compile firmware/protocol-test
make protocol-test-upload PORT=…                    # then read the result:
python3 scripts/serial-capture.py /dev/cu.usbserial-XXXX 10   # "RESULT pass=112 fail=0 …"
make clean
```

Never `swift build` or `arduino-cli compile` by hand for artifacts: the Makefile
carries flags that matter (SDK stamping, the build path, the version define).

## Structure

```
Package.swift                 Swift package at the root (check-org 12b reads it here)
Info.plist                    Template; build-app fills VERSION/BUNDLE_ID/APP_NAME
Sources/
  PanelCore/                  Pure logic: shared constants, version, single-instance
    Protocol/                 Wire protocol (v1 and v2): lines, strict base64, HKDF keys,
                              AES-GCM frames, HELLO/AUTH, readings/acknowledgements,
                              setup messages
    Setup/                    SetupExchange — the companion's side of a setup session
    Session/                  CompanionSession (one connection) and ConnectionSupervisor
                              (candidates, time limits, status; ADR-0001 decision 1)
    Metrics/                  Per-core CPU, memory breakdown, network meter, assembler;
                              RateRule/InterfaceResolver ported from net-meter,
                              CPUTicks/GPU parsing from load-spinner (origin in each file)
  PanelSystem/                OS readers (Mach, IOKit, sysctl, NWPathMonitor, memory
                              pressure) and MetricsCollector. Live tests
  M5SystemPanel/              The app: wiring only — AppModel, RunDriver (supervisor ↔
                              NWBrowser/NWConnection), SetupDriver (router probe, setup
                              session), SetupView, PanelApp (menu + setup window)
Tests/PanelCoreTests/        Includes ProtocolVectorTests (testdata/protocol.json)
Tests/PanelSystemTests/       Live: read this Mac's counters, unprivileged
testdata/protocol.json        Known answers: RFC 5869, NIST CAVP GCM, protocol vectors, rejects
firmware/
  libraries/PanelProtocol/    Protocol v2, panel side (C++, mbedTLS, no heap); shared by
                              the product sketch and the test sketch (--libraries)
  protocol-test/              On-device test sketch; vectors.h is generated (gitignored)
  m5-system-panel/            Arduino sketch (folder name = .ino name)
    m5-system-panel.ino       Boot (B held 3 s erases), mode dispatch, buttons, dimming
    src/panel_service.h       Constants shared with the companion; no Arduino headers
    src/config_store.*        NVS: SSID, password, device ID, key (version marker last)
    src/net_setup.*           Setup mode: scan, SoftAP + one-time password, SetupServer
    src/net_run.*             Wi-Fi, mDNS, accepts → SessionManager
    src/display.*             Five pages drawn through one 320x80 band, history
    src/backlight.*           Brightness levels: GPIO32 at 1 kHz / 14 bits, 2.2 power curve
scripts/                      codesign/notarize, release-brew.mk, gen-brew.sh, cask.rb.tmpl —
                              verbatim from nlink-jp/.github/templates;
                              gen-protocol-vectors.swift (protocol vectors),
                              gen-firmware-vectors.py (vectors.h for the test sketch),
                              serial-capture.py (reads the test sketch's result),
                              gen-icon.swift (draws assets/AppIcon-1024.png),
                              make-icns.sh (PNG → AppIcon.icns, from net-meter)
assets/                       AppIcon-1024.png — regenerate with gen-icon.swift, do not edit
spikes/                       Phase 0 probes and their results (README.md)
docs/{ja,en}/                 RFP, protocol v2 and ADRs (Japanese is primary)
```

## Non-negotiable rules

- **ADR-023 binds this project.** Read the documentation of every API, protocol
  and library default before designing against it; what the documentation does
  not state is observed on the real system (with the events logged) before it is
  relied on. The RFP marks those items "Phase 0".
- **Announce and undo machine-state changes.** Tests run on the maintainer's Mac.
  Before a test that joins a Wi-Fi network, registers an app with Launch
  Services, adds a login item or writes Keychain items, say so and have the
  removal ready; remove and record after the test. The local network permission
  is the exception: it cannot be reset on macOS (TN3179) and is kept by the
  maintainer's decision.
- **Launch the app with `open`, never the binary from Terminal.** Terminal-launched
  processes get local network access automatically (TN3179), which hides the
  deny path.
- **The panel accepts nothing that does not verify under the setup key.** An
  existing connection is replaced only after the new connection's first frame
  verifies. Never add a path that trusts the LAN.
- **The setup peer is the Wi-Fi router, nothing else.** A setup session is
  opened only over a connection pinned to the Wi-Fi interface, to that
  interface's router address (protocol §5.1). Never pick it from mDNS or from
  an address the user typed: the home Wi-Fi password travels in it.
- **Keychain items never synchronise**: they live in the file-based keychain
  (SecItem's macOS default), which iCloud Keychain never touches (TN3137);
  two Macs holding one key would fight over the panel. Do not add
  `kSecUseDataProtectionKeychain` — it needs a provisioning profile and brings sync.
- **No live Keychain tests**: they would write to the user's login keychain. The
  pending/commit rules are tested on MemoryRegistrationStore.
- **No OS-managed role.** No HID, no Bluetooth, no notifications. Buttons stay on
  the panel.
- **No community libraries** (ArduinoJson included). Apple frameworks on the Mac;
  libraries bundled with arduino-esp32 / ESP-IDF and M5Unified on the panel.
- **The service name `m5-system-panel` lives in three places** —
  `PanelService.name`, `Info.plist` `NSBonjourServices`, `panel_service.h`.
  `ServiceNameTests` keeps them equal; it is exactly 15 characters, the RFC 6335
  maximum, so it cannot grow.

## Gotchas

- **Protocol vectors come from a second implementation.** `scripts/gen-protocol-vectors.swift`
  reads the spec literally with CryptoKit; `ProtocolVectorTests` checks that
  `PanelCore` reproduces it, and the panel checks the same file with mbedTLS.
  Regenerate only when the spec changes, and never from `PanelCore` itself.
  It already caught one error of its own kind: the "longest" plaintext used
  19 nines, above the 2^63 − 1 maximum, and the implementation refused it.
- **`Measurement` is a Foundation type**; the readings message is `Readings`.
- **Two protocol versions, one difference.** v1 and v2 differ only in the
  trailing `bri` of the measurements (protocol §10); keys, frames and the
  `m5-system-panel/1` labels are shared, and the setup session (`SETUP 1`) is
  unchanged. `Readings.encoded(version:)` / `parse(_:version:)` take the version
  explicitly; `CompanionSession` uses HELLO's. The v2 rejects in testdata are the
  v1 rejects with ` bri=3` appended (so each still fails for its own reason) plus
  the `bri` cases.
- **Brightness is the Mac's.** The companion stores the level (UserDefaults
  `brightness`, default 3) and sends it every frame; the panel never stores it.
  What each level looks like is `backlight::kPercent` on the panel (chosen on the
  device, ADR-0003) — never send PWM values. Once `backlight::begin` has moved
  the channel to 14 bits, never call `M5.Display.setBrightness`: it writes 9-bit
  values into it. Only the fallback (not a BASIC, or the move failed) uses it.
- **"Connection refused" at companion launch is the setup probe**, not the panel:
  SetupDriver asks the Wi-Fi router's port 47110 once at start and retries up to
  3 times 5 s apart (4 refusals from the home router). Logs hash the addresses;
  the run session's flows resolve to the panel, the refused ones to the router.
- **The panel is tested on the device.** `make protocol-test` turns
  testdata/protocol.json into `vectors.h`; the sketch checks mbedTLS against
  RFC 5869 / NIST CAVP, the protocol vectors and every reject, and reports
  `RESULT pass=N fail=M … failures: …` on serial every 2 s (112 checks). A one-byte change to
  an expected key made 7 checks fail (keys and every c2p frame) — it can fail;
  accepting `bri=6` made exactly `reject.readings[18]` fail. The panel speaks v2
  only, so `gen-firmware-vectors.py` takes the v2 HELLO, frames and rejects.
- **The panel's decisions are pure too** (`panel_sessions.{h,cpp}`: SessionManager,
  SetupServer). The test sketch drives them with a simulated companion and a fake
  with another key; replacing the session at AUTH instead of after the first
  verified frame fails 5 checks (fake_refused among them).
- **Version check matches the whole line `m5-system-panel <version>`**: the linker
  merges the standalone `FW_VERSION` literal into that string's tail, so the bare
  version is not a line of `strings` output; a substring match would let
  `<version>-dirty` pass for `<version>`.
- **The app icon is required.** `build-app` fails without `assets/AppIcon-1024.png`, and
  `verify-release` looks for `AppIcon.icns` and `CFBundleIconFile` inside the release zip
  (v0.1.0 shipped with no icon).
- **`spctl --assess` can fail on its very first run** on a machine; run
  `make verify-release` again before concluding the app is not accepted.
- **Loop task stack: 16 KB** (`SET_LOOP_TASK_STACK_SIZE`). The protocol code keeps
  its buffers on the stack (~3 KB per line); the default 8 KB overflowed as a
  "Double exception" in test_sessions. The test sketch reports `stack_free_min`
  (5,488 B at 16 KB); the product sketch sets the same size.
- **`arduino-cli monitor` exits when its stdin reaches EOF**; `serial-capture.py`
  keeps stdin an open pipe. Opening the port reboots the board (boot ROM noise
  first), which is fine for a test that reports repeatedly.
- **No templates in `.ino` files**: the Arduino preprocessor's prototype
  generation breaks them (`'N' was not declared`). Use a macro or a `.cpp`.
- **Firmware is released as four images, not the merged one.** The 16 MB
  `.merged.bin` takes ~12 minutes at 230400 baud and overwrites NVS (the
  settings) on every update. The zip carries bootloader/partitions/boot_app0/app
  for the offsets `arduino-cli upload` uses (0x1000, 0x8000, 0xe000, 0x10000);
  the README's esptool line was run from the zip and verified on the device.
- **Ported files carry their origin** (`// Copied from util-series/<tool> <commit> …`).
  "ADR-0001" inside them means *that tool's* ADR; the references say so.
- **No P/E per core** (RFP A4): `cores` is a plain list in logical CPU order.
- **The supervisor is pure.** Time, randomness and the network live in the app;
  `ConnectionSupervisor` only turns events into actions, so every ADR-0001 row is
  a unit test. Keep it that way — a timer or an NWConnection inside it would make
  the rows untestable.

- **Firmware build path.** `--output-dir` / `-e` make the ESP32 core copy
  binaries (with absolute paths) into `firmware/m5-system-panel/build/`. The
  Makefile builds with `--build-path dist/firmware` and fails if that folder
  appears.
- **Version define.** `compiler.cpp.extra_flags` must be wrapped in single quotes
  as a whole (arduino-cli splits recipes itself). `make firmware` checks the
  version string is in the `.bin`.
- **Upload speed.** The core's default 1500000 baud fails on BASIC v2.7's CH9102F
  from macOS; the Makefile pins 230400.
- **Pinned versions.** `make firmware-deps` refuses any other `esp32:esp32` core
  or M5Unified/M5GFX version than the Makefile names. Upgrading is a deliberate
  change: bump the pin, rebuild, re-run the on-device checks.
- **Flash layout.** The board has 16 MB; the Makefile passes
  `FlashSize=16M,PartitionScheme=huge_app` (3 MB app, no OTA) to both compile and
  upload (ADR-0001). Wi-Fi + mDNS alone used 88 % of the default 1.25 MB. A board
  flashed with the old layout is erased before flashing the new one.
- **No PSRAM.** With Wi-Fi up, ~155 KB is free and the largest block is ~59 KB: a
  full-screen 16-bit buffer (150 KB) cannot be allocated. Draw in bands of at most
  51,200 B (320×80) (ADR-0001).
- **Connection supervision (ADR-0001).** `.preparing` never ends by itself (prompt
  race, absent panel) — time it out at 10 s. `.waiting` resumes by itself — leave
  it. Local network denial shows as `.waiting(.dns(-65570))` with
  `unsatisfiedReason = notAvailable` on macOS 27. Browse results do not report a
  panel going away; status comes from the connection and acks.
- **System Settings shows the executable name** in the Local Network list, so
  `M5SystemPanel` is user-facing.
- **zsh's `log` builtin** shadows `/usr/bin/log`; call it by full path when reading
  the unified log.
- **`git describe` and untracked files.** `--dirty` only sees tracked changes, so
  a build with new untracked sources is not marked dirty.

## Design reference

- RFP: [docs/ja/m5-system-panel-rfp.ja.md](docs/ja/m5-system-panel-rfp.ja.md)
  ([English](docs/en/m5-system-panel-rfp.md)) — scope, the rejected alternatives
  (USB serial, TF card, BLE, captive portal, trusting the LAN), the state tables
  and the platform constraints with their sources.
- ADR-0001 ([ja](docs/ja/adr/0001-phase0-premises.ja.md), [en](docs/en/adr/0001-phase0-premises.md))
  — what Phase 0 measured and decided: connection supervision, partitions,
  drawing buffers, the setup Wi-Fi clean-up guidance.
- ADR-0002 ([ja](docs/ja/adr/0002-crypto-and-setup-binding.ja.md), [en](docs/en/adr/0002-crypto-and-setup-binding.md))
  — AES-256-GCM instead of ChaCha20-Poly1305 (with the library evidence),
  HKDF Expand only, the setup peer bound to the Wi-Fi router, the accepted
  residual risk (disruption, not falsification).
- ADR-0003 ([ja](docs/ja/adr/0003-brightness.ja.md), [en](docs/en/adr/0003-brightness.md))
  — brightness held by the Mac and sent with every frame as a level 1–5,
  protocol v2, the level percentages chosen on the device.
- Organization ADR-023 (`nlink-jp/.github`, `adr/023-documentation-not-conjecture.md`).
- Measurement code to copy (with its tests): CPU/GPU from `load-spinner`, network
  counters from `net-meter` (util-series).
