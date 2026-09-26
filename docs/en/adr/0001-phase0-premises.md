# ADR-0001: What the Phase 0 measurements decide — connection supervision, memory and partitions, cleaning up after the setup Wi-Fi

> English translation. The Japanese version (`docs/ja/adr/0001-phase0-premises.ja.md`) is the primary document.

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-09-26 |
| Binds | m5-system-panel |
| Decision makers | nlink-jp maintainers |
| Triggered by | RFP §4 Phase 0 (observe on real hardware what the documentation does not state before the design is fixed; organization ADR-023) |

## Context

The RFP set seven behaviours the documentation does not state to be measured in Phase 0 before the design is
fixed. The probes, procedures and raw results are in `spikes/README.md`; this record gives only the results and
what they decide. One Mac (macOS 27.0, wired Ethernet as the primary service, Wi-Fi joined to the same LAN) and
one M5Stack BASIC v2.7 with no battery fitted (16 MB flash). Sample counts are small (see "Samples").

| # | Measured | Samples |
|---|---|---|
| 1 | After Wi-Fi, mDNS and the TCP listener, ~155 KB free; largest block 59,380 B; a full-screen 16-bit buffer (153,600 B) cannot be allocated. The probe firmware alone uses 88 % of the default 1.25 MB app partition | 1 |
| 2 | Joining the setup Wi-Fi adds it to Known Networks at once. When it disappears the Mac rejoins its previous Wi-Fi by itself after ~11 s. `networksetup -removepreferredwirelessnetwork` removes the entry but leaves the "AirPort network password" in the System keychain (admin rights needed to delete) | 1 |
| 3a | A connection created while the permission prompt was up stayed in `.preparing` for over 2 minutes after the user allowed it and never retried (a lower-layer path failed with "Local network prohibited" before the grant propagated) | 1 |
| 3b | Switching the permission off fails the established connection at once with POSIX 53. New connections enter `.waiting(-65570: PolicyDenied)` with `unsatisfiedReason = notAvailable` (not TN3179's `localNetworkDenied`); the browser reports nothing. Switching it back on, the OS moves a `.waiting` connection to `.preparing` by itself | 2 |
| 3c | System Settings lists the app by its executable name | 1 |
| 4 | The Mac could still communicate for ~23 s after willSleep; after wake the 5 s watchdog and re-browsing reconnected 1.6 s before didWake. USB power continued during sleep (no battery, and uptime did not break) | 1 |
| 5 | The 5 s watchdog noticed panel power loss after 5.1 s; an untouched connection failed with POSIX 60 after ~30 s. With the panel absent, new connections stay in `.preparing`. The browser reported no `removed` for over 2 minutes and nothing on return | 1 |
| 6 | This Mac's `AGXAcceleratorG14X` exposes `Device Utilization %`, and it moves | 1 |
| 7 | The ESP32 RNG is a true RNG only while Wi-Fi or Bluetooth is enabled (ESP-IDF v5.5 documentation) | documented |
| Note | After a connection replacement the panel's free heap dropped ~12 KB (~0.2 KB after the second) | 2 |

## Decision

### 1. How the companion supervises its connection (3a, 3b, 4, 5)

| State | Handling |
|---|---|
| `.preparing` for 10 s | Cancel and recreate (in 3a and 5 the OS never left this state by itself) |
| `.waiting` | Leave the retry to the OS. If the error is `.dns(-65570)`, show "Local network permission required". Treat `unsatisfiedReason == .localNetworkDenied` (the documented value) the same |
| `.failed` / `.cancelled` | Recreate after 5 s |
| `.ready` with no ack for 5 s | Show "Not responding", cancel the old connection and recreate (the OS takes ~30 s to decide) |

- Browse results do not decide whether the panel is present (5: neither its loss nor its return was reported).
  The browser only supplies the endpoint (the service name); the status shown comes from the connection and acks.
- Nothing special on didWake or willSleep (4: supervision and re-browsing reconnected before didWake, and the Mac
  can still communicate after willSleep).
- The first launch can hit the permission-prompt race (3a, observed once). The 10 s `.preparing` rule above recovers
  it, so nothing more is added.

### 2. Panel memory and partitions (1)

- Board options `FlashSize=16M`, `PartitionScheme=huge_app` (3 MB app, no OTA). OTA is out of scope in the RFP;
  the probe firmware alone used 88 % of the default partition.
- Drawing buffers are capped at 51,200 B each (320×80, 16-bit); no full-screen buffer.
- Phase 1 re-measures free memory with cryptography and drawing loaded, and runs **a soak of several hundred
  connection replacements** to confirm the drop in the note stops (if it does not, the connection handling is revisited).

### 3. The panel while the Mac sleeps (4)

USB power continues during sleep, so the screen stays lit. The RFP's "dim after waiting for data" is required.

### 4. Guidance for removing the setup Wi-Fi (2)

The setup window's closing guidance will not use the `networksetup` method, which leaves the password in the System
keychain. Whether System Settings' "Remove From List" removes the password as well is not measured. **During the
end-to-end setup test in Phase 1, remove it that way and check the keychain** before the wording is fixed.

### 5. Other

- Keys and the one-time password are generated after Wi-Fi is started (7).
- GPU as in the RFP (6). Confirmed on this one Mac model only.
- The companion's executable name `M5SystemPanel` is treated as a user-facing name, since System Settings shows it (3c).

### State table changes (to RFP §7)

Rows added to the companion table; rows marked "Phase 0" are settled by the decisions above.

| State | Event | Menu | Source |
|---|---|---|---|
| Searching | Connection in `.preparing` for 10 s | Searching (recreate) | Measured 3a, 5 |
| Connected | Permission revoked | Permission required (the connection fails with POSIX 53) | Measured 3b |
| No permission | Permission restored | Connected (the OS resumes the `.waiting` connection) | Measured 3b, TN3179 |
| Connected | Sleep → wake | Connected (5 s supervision and re-browsing recover before didWake) | Measured 4 |

## Consequences

- The companion carries a small state machine that supervises one connection by its state. The durations (10 s,
  5 s, 5 s) are injectable so the transitions are unit-tested.
- The partition change moves the flash layout relative to earlier firmware; flashing starts from an erase.
- Many observations are single samples. 3a (permission race) and 4 (sleep) in particular get further records if the
  Phase 1 end-to-end tests observe them again.
- Nothing was measured on macOS 26 (the verification VM has no Wi-Fi). If the minimum stays at 26, the README does
  not claim it until 3, 4 and 5 are checked on a macOS 26 machine.

## Alternatives considered

| Option | Why not |
|---|---|
| Time out `.waiting` as well | In 3b the OS left `.waiting` by itself; recreating can cancel that resumption (it happened once) |
| Show status from the browser's `removed` / `added` | In 5 it reported nothing for over 2 minutes of power loss |
| Recreate the connection on didWake | In 4 supervision had reconnected before didWake arrived; it would recreate twice |
| Keep the default partition and cut features to fit | The probe alone used 88 %; no room for cryptography, drawing and four pages |
| 8 MB layout with OTA (two 3 MB app slots) | OTA is out of scope; it only reserves space that is never used |
