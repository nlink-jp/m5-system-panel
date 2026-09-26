# Phase 0 probes and results

The RFP's Phase 0 (§4) measures what the documentation does not state before the
design is fixed (organization ADR-023). This file records how each item was
measured and what was observed; the design consequences go to the Phase 0 ADR.
Every claim below is labelled **measured**, **documented** or **inferred**.

Environment: macOS 27.0 (26A428) on Apple Silicon, wired Ethernet as the primary
service with Wi-Fi also joined to the same LAN; M5Stack BASIC v2.7
(ESP32-D0WDQ6-V3 rev 3.1), `esp32:esp32` 3.3.8, M5Unified 0.2.14, M5GFX 0.2.27.
Measured 2026-09-26.

## Probes

| Probe | What it is |
|---|---|
| `gpu_keys.swift` | Read-only: lists the `PerformanceStatistics` keys of every IOAccelerator service and samples `Device Utilization %` |
| `firmware/phase0/` | STA: joins the network in `wifi_local.h` (gitignored), advertises `_m5-system-panel._tcp`, accepts one TCP client and sends an `ack` line with its own counters every second. Hold B at boot: scans, makes a 12-character password after the radio is up, starts the setup SoftAP |
| `mac/Phase0Probe.swift` | An app bundle with the companion's bundle id (so the local network permission it triggers is the companion's). Logs browser, connection, viability, path, sleep/wake events and every ack. Retries every 5 s with no connection, replaces a connection not ready after 10 s, opens a new connection after 5 s without an ack but lets the old one fail on its own |

`make spike-firmware`, `make spike-upload PORT=…`, `make spike-app`. Launch the
app with `open --env PHASE0_LOG=<file> dist/spike/Phase0Probe.app` — never the
binary from Terminal (TN3179: Terminal children get local network access).

## Results

### 1. Memory on the panel (measured)

With Wi-Fi joined, mDNS advertising and the TCP server listening:

| Point | Free heap |
|---|---|
| Boot | 269,560 B |
| After Wi-Fi, mDNS and server | 210,000 B |
| After a 320×80 16-bit sprite (51,200 B) | 156,748 B |
| Running, with one client | ~154,700 B (minimum seen 149,564 B) |

- Largest allocatable block: **59,380 B**. A full-screen 16-bit sprite
  (153,600 B) could not be allocated after Wi-Fi started (`full=0`).
- The probe firmware (Wi-Fi + mDNS + TCP, no crypto, no pages) uses **88 %** of
  the default 1.25 MB app partition.

### 2. Setup SoftAP from the Mac (measured)

- Joining `m5-system-panel-<id>` from the Wi-Fi menu with the 12-character
  password worked; the Mac had a DHCP address from the panel 3 s after joining.
- The network was added to **Known Networks at the moment of joining**.
- When the panel restarted in STA mode and the SoftAP disappeared, the Mac's
  Wi-Fi **returned to the previous network by itself, about 11 s later**.
- `networksetup -removepreferredwirelessnetwork en1 <ssid>` removed the Known
  Networks entry without admin rights, **but left an "AirPort network password"
  item in the System keychain**, which needs admin rights to delete
  (`sudo security delete-generic-password -a <ssid> -D "AirPort network password"
  /Library/Keychains/System.keychain` removed it). Whether System Settings'
  "Remove From List" removes both is not yet measured.
- The current SSID cannot be read by an unprivileged process here:
  `ipconfig getsummary` shows it redacted and `networksetup -getairportnetwork`
  reports "not associated". The logger identified the network by address and router.

### 3. Discovery and the local network permission (measured)

- **The prompt race.** The first launch showed the prompt; the browser found the
  panel the moment the user clicked Allow, the connection was created 1 ms later,
  and the system log shows its resolved IPv4 child failing with
  "Local network prohibited" 60 ms after that — the grant had not reached the
  lower layer yet. The connection then stayed in **`.preparing` indefinitely**
  (over 2 minutes, never `.waiting` or `.failed`) and never retried by itself.
- After relaunching with the permission granted: browse result in 1 ms, `.ready`
  in 0.16 s.
- **Permission switched off while connected:** the established connection failed
  immediately with POSIX 53 (Software caused connection abort). New connections
  entered `.waiting(-65570: PolicyDenied)` with `unsatisfiedReason = notAvailable`
  — not `.localNetworkDenied` as TN3179 describes. The browser stayed `.ready`
  and reported nothing.
- **Switched back on:** a connection in `.waiting` moved to `.preparing` on its
  own (as TN3179 documents); a fresh connection was `.ready` in 0.25 s.
- System Settings lists the app by its **executable name** (`Phase0Probe`), not
  `CFBundleName`.

### 4. Sleep and wake (measured)

Sleep from the Apple menu, about 3.5 minutes asleep.

- `willSleep` arrived, then **acks kept arriving for ~6 s** and the Mac still had
  network for **~23 s** before it actually slept (Wi-Fi stayed up after wired
  Ethernet went down; the browser reported `removed`, then `added` on `en1`).
- During that window the 5 s watchdog fired and a new connection over Wi-Fi was
  `.ready` in 0.2 s; the panel replaced the old connection.
- On wake, the watchdog fired on the first timer tick, the browser re-added the
  panel, and a new connection was `.ready` in 0.2 s — **1.6 s before
  `didWake`** was delivered (`screensDidWake` came first). The panel replaced the
  old connection, which the Mac then saw fail with POSIX 54 (reset by peer).
- **USB power continued during sleep** on this Mac and port: the panel has no
  battery fitted, and its uptime advanced by the wall-clock time with no reboot.
- Free heap on the panel dropped ~12 KB after the first connection replacement
  (156 KB → 143 KB) and ~0.2 KB after the second — not a steady leak in two
  samples; a long replacement soak is needed before calling it one.

## Machine state changed by these tests, and its removal

| Change | Removed |
|---|---|
| Probe firmware with Wi-Fi credentials on the panel | `esptool erase-flash`; NVS, app start and mid-app regions read back as all 0xFF; scaffold firmware flashed |
| Launch Services registrations: the probe **and the never-launched `dist/M5SystemPanel.app`** (same bundle id) | `lsregister -u` for both; `lsregister -dump` shows neither |
| Known Networks entry for the setup SoftAP | `networksetup -removepreferredwirelessnetwork` |
| System keychain "AirPort network password" for the setup SoftAP | `sudo security delete-generic-password …` (by the maintainer) |
| `wifi_local.h` (gitignored) | deleted |
| Local network permission for `jp.nlink.m5-system-panel` | kept — cannot be reset on macOS (TN3179); the companion needs it (maintainer's decision) |

The panel's flash is 16 MB (`esptool flash-id`: manufacturer 0x46, device 0x4018).

### 5. Panel power loss (measured)

- The 5 s ack watchdog fired 5.1 s after the last ack.
- Left alone, the old connection failed with POSIX 60 (Operation timed out)
  **about 30 s after the last ack** (the probe kept sending once a second).
- With the panel off, new connections stayed in `.preparing` — never `.waiting`
  or `.failed`; only the 10 s replacement retried them.
- **The Bonjour browser reported no `removed` while the panel was off (over 2
  minutes) and nothing when it came back** under the same name. Browse results
  do not tell whether the panel is there.
- After power-on the panel was reachable ~3.7 s after boot.

### 6. GPU utilization key (measured)

One IOAccelerator service (`AGXAcceleratorG14X`) exposes `Device Utilization %`
(also `Renderer Utilization %`, `Tiler Utilization %`, memory counters). Sampled
at 1 Hz it read 0, 0, 13, 0, 0 on an idle desktop — it moves.

### 7. Hardware RNG (documented)

ESP-IDF v5.5, *Random Number Generation*: `esp_random()` returns true random
numbers while Wi-Fi or Bluetooth is enabled; after the application starts and
before either is initialised it is pseudo-random. Keys and the SoftAP password
are therefore generated after the radio is up (the probe scans first).

## Phase 1 checks

### Wi-Fi router address without privileges (measured)

`spikes/wifi_router.swift` reads `State:/Network/Service/*/IPv4` from
`SCDynamicStore` and picks the service whose `InterfaceName` is the IEEE 802.11
interface (`SCNetworkInterfaceCopyAll`). As an unprivileged process it found
the Wi-Fi interface and its `Router` value (macOS 27.0, 2026-09-26). This settles
the open item in ADR-0002: protocol §5.1 can be implemented with a public API
and no extra permission.

## End-to-end test (2026-09-27)

Product firmware on the BASIC, the companion launched with `open`, setup done by
the maintainer, macOS 27.0.

- **Removing the setup Wi-Fi (settles ADR-0001 decision 4, measured):** System
  Settings › Wi-Fi › Known Networks › "Remove From List" removed both the Known
  Networks entry and the "AirPort network password" in the System keychain
  (`networksetup -listpreferredwirelessnetworks` and `security
  find-generic-password … /Library/Keychains/System.keychain` found neither).
  `networksetup -removepreferredwirelessnetwork` had left the password (item 2).
  The setup window's closing guidance names the System Settings route.
- **Keychain (measured):** after setup the registration was in the file-based
  login keychain as `active`; the `pending` entry was gone.
- **Sleep and wake (measured, once):** the companion cancelled the old connection
  and had a new one `.ready` about 2 s later, before the wake notification's time
  in `pmset -g log`.
- **Pop at boot (measured):** "sometimes" with M5Unified's default speaker set-up
  (it drives GPIO25 low in `begin()`); 0 of 5 power cycles with
  `internal_spk = false`.
- **Setup probing loop (measured, fixed):** the companion probed the home router
  about every 4 s (90 attempts in 6 minutes): Wi-Fi path updates kept resetting
  the retry budget while the router never changed. It now probes only when the
  Wi-Fi route changes.
- **Input source (observed):** SwiftUI's SecureField left a Japanese input source
  active and beeped on every key; the field now restricts its input context to
  Roman sources and the menu bar switched to "A".
