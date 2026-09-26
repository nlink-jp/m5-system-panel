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
- RFP ([Japanese](docs/ja/m5-system-panel-rfp.ja.md), [English](docs/en/m5-system-panel-rfp.md)).
