# Changelog

All notable changes to m5-system-panel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
Semantic Versioning.

## [0.1.0] - Unreleased

### Added

- Project scaffold: the menu bar companion (Swift package at the repository
  root) and the M5 firmware (`firmware/m5-system-panel/`), each showing only its
  name and version.
- The Bonjour service name `m5-system-panel`, shared by the companion, the
  firmware and `Info.plist`, with a test that checks it against RFC 6335 §5.1
  and that the three agree.
- The firmware is built for 16 MB flash with a 3 MB app partition
  (`huge_app`, no OTA).
- Phase 0 probes (`spikes/`) and ADR-0001, which records the measurements and
  what they decide ([Japanese](docs/ja/adr/0001-phase0-premises.ja.md),
  [English](docs/en/adr/0001-phase0-premises.md)).
- The companion app: menu (status, start setup, unregister, launch at login),
  the setup window, the run-session driver and the setup driver; registrations
  in the file-based login keychain (pending until DONE, never synchronised).
- The panel firmware: setup mode (scan, setup Wi-Fi with a one-time password,
  the setup session), normal operation (Wi-Fi, Bonjour, sessions), four pages
  with five minutes of history, "waiting for data" and the backlight going off
  after five minutes without data. Buttons: A previous, C next, B overview;
  holding B for 3 s at power-on erases the settings.
- Panel side of protocol v1 (`firmware/libraries/PanelProtocol`, mbedTLS with
  hardware AES) and an on-device test sketch that checks it against
  `testdata/protocol-v1.json`, plus the panel's session and setup logic against a
  simulated companion: 99 checks pass on a BASIC v2.7.
- Setup-session messages and the companion's setup exchange (provisional key
  committed only on `DONE`).
- Metrics: per-core CPU, memory breakdown and swap, memory pressure, GPU, the
  primary interface's rates; `PanelSystem` reads them from the OS.
- The companion's session and connection supervisor (ADR-0001 decision 1).
- Protocol core in `PanelCore` (strict base64, line buffer, HKDF-SHA256 session
  keys, AES-256-GCM frames with counter nonces, HELLO/AUTH, readings and
  acknowledgements) and its known-answer tests (`testdata/protocol-v1.json`).
- Wire protocol v1 ([Japanese](docs/ja/protocol.ja.md), [English](docs/en/protocol.md))
  and ADR-0002: AES-256-GCM with HKDF-SHA256 Expand, the setup peer bound to
  the Wi-Fi router ([Japanese](docs/ja/adr/0002-crypto-and-setup-binding.ja.md),
  [English](docs/en/adr/0002-crypto-and-setup-binding.md)).
- RFP ([Japanese](docs/ja/m5-system-panel-rfp.ja.md), [English](docs/en/m5-system-panel-rfp.md)).
