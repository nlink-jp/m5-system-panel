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
wire format is [protocol v1](docs/ja/protocol.ja.md) ([en](docs/en/protocol.md)).

**Current state: Phase 1, protocol v1 specified and reviewed** (ADR-0002); test
vectors and implementation are next. Both parts still only show their name and
version. Phase 0 measurements: `spikes/README.md`, decisions: ADR-0001.

## Build & test

```bash
make test             # swift test — also checks the constants shared with the firmware
make build            # companion release binary (.build/release)
make build-app        # dist/M5SystemPanel.app, signed (Developer ID)
make package          # + notarize, staple, zip (release only)
make firmware         # dist/firmware/m5-system-panel.ino.bin (pinned core/libs)
make firmware-upload PORT=/dev/cu.usbserial-XXXX   # flash at 230400 baud
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
    Protocol/                 Wire protocol v1: lines, strict base64, HKDF keys,
                              AES-GCM frames, HELLO/AUTH, readings/acknowledgements
  M5SystemPanel/              The app: wiring only
Tests/PanelCoreTests/        Includes ProtocolVectorTests (testdata/protocol-v1.json)
testdata/protocol-v1.json     Known answers: RFC 5869, NIST CAVP GCM, protocol vectors, rejects
firmware/
  m5-system-panel/            Arduino sketch (folder name = .ino name)
    m5-system-panel.ino
    src/panel_service.h       Constants shared with the companion; no Arduino headers
scripts/                      codesign/notarize — verbatim from nlink-jp/.github/templates;
                              gen-protocol-vectors.swift — regenerates the protocol vectors
spikes/                       Phase 0 probes and their results (README.md)
docs/{ja,en}/                 RFP and ADRs (Japanese is primary)
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
- **Keychain items never synchronise** (`…ThisDeviceOnly`, not synchronizable):
  two Macs holding one key would fight over the panel.
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
  `PanelCore` reproduces it, and the panel will check the same file with mbedTLS.
  Regenerate only when the spec changes, and never from `PanelCore` itself.
  It already caught one error of its own kind: the "longest" plaintext used
  19 nines, above the 2^63 − 1 maximum, and the implementation refused it.
- **`Measurement` is a Foundation type**; the readings message is `Readings`.

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
- Organization ADR-023 (`nlink-jp/.github`, `adr/023-documentation-not-conjecture.md`).
- Measurement code to copy (with its tests): CPU/GPU from `load-spinner`, network
  counters from `net-meter` (util-series).
