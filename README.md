# m5-system-panel

[日本語](README.ja.md)

An M5Stack BASIC on your desk becomes a small instrument panel for one Mac: CPU,
GPU, memory and network, shown all the time. A menu bar app on the Mac (the
companion) measures the values and sends them over your Wi-Fi; the panel only
draws them, and its three buttons switch pages.

> macOS releases are **Developer ID signed and Apple-notarized** (stapled). They
> launch without Gatekeeper prompts and work offline.

## What it does

- **Five pages** on the panel: an overview of all four readings, CPU (overall and
  per core), GPU, memory (breakdown, pressure, swap), and network (upload up in red,
  download down in green): about five minutes of history on each item's page and
  about two and a half on the overview.
- **Buttons:** A previous page, C next page, B back to the overview.
- **Wi-Fi, no cable for data.** The USB cable only powers the panel.
- **Only your Mac can drive your panel.** Setup shares a key between the panel
  and the companion; the panel ignores anything that is not sent with that key,
  so several panels and Macs on one network do not interfere.
- **Brightness in five levels, from the menu.** The level is stored on the Mac and
  sent with every second's values (the panel stores nothing). From power-on until
  the first values arrive the panel lights at level 3.
- **The panel rests when the Mac sleeps.** After 3 s without values it shows
  "waiting for data"; after 5 minutes the screen goes dark. Values arriving or a
  button press bring it back.

## Requirements

- M5Stack BASIC v2.7
- A Mac with Apple Silicon, macOS 26 or later
- A 2.4 GHz Wi-Fi network (WPA2 or WPA3 Personal, or open) that lets devices see
  each other. Guest networks that isolate clients and enterprise authentication
  (802.1X) are not supported. A network missing from the list can be typed in, but
  joining a hidden SSID has not been tested.

## Installation

### Companion (Mac)

```bash
brew install --cask nlink-jp/tap/m5-system-panel
```

Or download `m5-system-panel-v<version>-darwin-arm64.zip` from
[Releases](https://github.com/nlink-jp/m5-system-panel/releases) and move
`M5SystemPanel.app` to Applications.

On first launch macOS asks for **local network** access. Allow it: the companion
needs it to find the panel and send values. You can change it later in System
Settings › Privacy & Security › Local Network (listed as "M5SystemPanel").

### Firmware (M5Stack BASIC)

Download `m5-system-panel-firmware-v<version>-m5stack-basic.zip` from
[Releases](https://github.com/nlink-jp/m5-system-panel/releases), unzip it, and
flash it with Espressif's [esptool](https://docs.espressif.com/projects/esptool/) (5.x).
esptool 5 needs Python 3.10 or later, so `pip` with macOS's bundled Python (3.9)
installs the old 4.x. Install it with Homebrew:

```bash
brew install esptool
esptool version
```

Check that `esptool version` reports 5.x.

Connect the M5 over USB and find its port (`/dev/cu.usbserial-…`).

```bash
ls /dev/cu.usbserial-*
```

**The first time**, erase the flash first (so no other firmware's settings remain).

```bash
esptool --chip esp32 --port /dev/cu.usbserial-XXXX erase-flash
```

Flash from the unzipped folder (230400 bps; faster speeds can stop part-way).

```bash
esptool --chip esp32 --port /dev/cu.usbserial-XXXX --baud 230400 write-flash -z --flash-mode keep --flash-freq keep --flash-size keep 0x1000 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 m5-system-panel.bin
```

To **update** to a new version, flash without erasing; the settings stay.

**When updating from v0.1.x to v0.2 or later**, update the companion first. The new
companion also works with the old firmware (without the brightness), but the old
companion reports "The panel's firmware does not match" for the new firmware
([protocol §10](docs/en/protocol.md)).

## First setup

1. With no settings the M5 starts in **setup mode** and shows the setup Wi-Fi's
   name (`m5-system-panel-XXXX`) and a one-time password.
2. Join that network from the Mac's Wi-Fi menu (the password is on the M5's screen).
3. Choose "Start setup…" in the companion's menu, then "Show the panel's networks" in the window.
4. Pick the Wi-Fi the panel should join, enter its password and press "Give the settings to the panel".
5. The panel restarts and joins your Wi-Fi. The Mac returns to its usual network once the setup Wi-Fi disappears.
6. The setup Wi-Fi is not needed any more. In System Settings › Wi-Fi › Known Networks,
   choose "Remove From List" in the "…" menu of `m5-system-panel-XXXX`; this removes its saved password too.

**To set up again**, hold the M5's B button while powering it on and keep holding for
3 seconds, until the prompt goes away. The panel forgets its settings and starts in setup mode.

## Menu

The companion's menu and window are in Japanese; the labels in this README are translations.

| Item | What it does |
|---|---|
| Status | Connected (panel XXXX) / Searching for panel XXXX / Panel XXXX is not responding / Local network permission required / The panel's firmware does not match / Not set up |
| Brightness | Chooses the panel's screen brightness, 1 (dark) to 5 (bright); shown when a panel is registered. Not selectable while connected to a panel with v0.1.x firmware, with a note that it needs updating |
| Start setup… | Opens the setup window; shown when no panel is registered or a panel in setup mode is found |
| Unregister panel | Deletes the key stored on this Mac (setup is needed again) |
| Launch at login | Starts the companion when you log in |
| Quit | Quits the companion |

## What is stored, and how to remove it

| Where | What | Removal |
|---|---|---|
| The Mac's login keychain (item "m5-system-panel (active)") | The panel's ID and key; never synchronised through iCloud | "Unregister panel" in the menu |
| The Mac's UserDefaults (`brightness` in `jp.nlink.m5-system-panel`) | The brightness level | `defaults delete jp.nlink.m5-system-panel brightness` (level 3 again at the next launch) |
| The M5's flash (NVS) | Your Wi-Fi's name and password, the panel's ID and key | Hold B at power-on for 3 s; before giving the M5 away, `esptool … erase-flash` |

The panel's NVS is not encrypted: the key and the Wi-Fi password are in its flash as plain text.

## Security

- The panel shows only the values of the Mac it shared a key with at setup. Values
  travel encrypted; anything sent with another key, altered, or replayed is dropped.
- Someone malicious on the same network can **stop** the display; they cannot make it show false values.
- The setup exchange is protected only by the setup Wi-Fi's encryption (its one-time password appears only on the panel's screen).

## Documents

- [Wire protocol](docs/en/protocol.md)
- [RFP (scope and design decisions)](docs/en/m5-system-panel-rfp.md)
- ADRs: [0001 what the measurements decided](docs/en/adr/0001-phase0-premises.md), [0002 cryptography and the setup peer](docs/en/adr/0002-crypto-and-setup-binding.md), [0003 screen brightness](docs/en/adr/0003-brightness.md)

## Building from source

Companion (Swift 6, Xcode command line tools):

```bash
make test        # unit tests
make build-app   # dist/M5SystemPanel.app (signed with your Developer ID)
```

Firmware (arduino-cli with the `esp32:esp32` core 3.3.8, M5Unified 0.2.14 and
M5GFX 0.2.27 installed):

```bash
make firmware                                   # dist/firmware/
make firmware-upload PORT=/dev/cu.usbserial-XXXX
```

## License

[MIT](LICENSE)
