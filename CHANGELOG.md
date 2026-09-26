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
- Wire protocol v1 ([Japanese](docs/ja/protocol.ja.md), [English](docs/en/protocol.md))
  and ADR-0002: AES-256-GCM with HKDF-SHA256 Expand, the setup peer bound to
  the Wi-Fi router ([Japanese](docs/ja/adr/0002-crypto-and-setup-binding.ja.md),
  [English](docs/en/adr/0002-crypto-and-setup-binding.md)).
- RFP ([Japanese](docs/ja/m5-system-panel-rfp.ja.md), [English](docs/en/m5-system-panel-rfp.md)).
