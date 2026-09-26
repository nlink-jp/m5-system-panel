# m5-system-panel

[日本語](README.ja.md)

An M5Stack BASIC on your desk becomes a small instrument panel for one Mac: CPU,
GPU, memory and network, shown all the time. A menu bar app on the Mac (the
companion) measures the values and sends them over your Wi-Fi; the panel only
draws them, and its three buttons switch pages.

> **Status:** in development. There is no release yet, and the panel does not
> show any measurements so far.

## What it will do

- **Four pages** on the panel: an overview of all four readings, CPU (overall and
  per core), GPU and memory, and network (up/down). A: previous page, C: next page,
  B: back to the overview.
- **Wi-Fi, no cable for data.** The USB cable only powers the panel.
- **Only your Mac can drive your panel.** Setup shares a key between the panel
  and the companion; the panel ignores anything that is not sent with that key,
  so several panels and Macs on one network do not interfere.
- **Setup from the companion.** On first start the panel opens a temporary Wi-Fi
  network with a one-time password shown on its screen; join it from the Mac and
  finish setup in the companion.

## Requirements

- M5Stack BASIC v2.7
- A Mac with Apple Silicon, macOS 26 or later
- A 2.4 GHz Wi-Fi network (WPA2 or WPA3 Personal) that lets devices see each other

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
