# ADR-0003: The Mac holds the screen brightness and sends it with every second's measurements

> English translation. The Japanese version (`docs/ja/adr/0003-brightness.ja.md`) is the primary document.

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-10-05 |
| Binds | m5-system-panel |
| Decision makers | nlink-jp maintainers |
| Triggered by | The maintainer's request: "set the M5's screen brightness from the companion" |

## Context

The v0.1 panel lights the screen at a fixed `M5.Display.setBrightness(128)` and turns it off after 5 minutes
without data (ADR-0001). There is no way to change the brightness.

Checked before designing:

- **Protocol v1 is strict about form.** The measurement fields are fixed in order and number, and a receiver
  closes on a malformed plaintext (§4.4). A v1 panel would close every connection that sends one more field. The
  companion refuses a `HELLO` whose version is not `1` as "firmware does not match" (§4.1). However the field is
  added, it raises the version.
- **With M5GFX's defaults the BASIC's backlight has no dark side** (knowledge `embedded.md`, "The M5Stack BASIC's
  backlight does not dim at 44.1 kHz PWM", observed on the device on 2026-09-25). M5GFX drives GPIO32 at 44.1 kHz,
  9 bits, and even 1% is comfortably readable. Moving the same channel to 1 kHz, 14 bits with
  `ledcChangeFrequency(32, 1000, 14)` and multiplying full on (16383) by `(percent/100)^2.2` gave nearly even steps
  down to the dark end. M5GFX 0.2.27 uses `ledcAttach(pin, freq, bits)` on arduino-esp32 3.x (`Light_PWM.cpp`), so
  the pin number addresses that channel.
- **The companion is a menu-style `MenuBarExtra`** (RFP §2). A continuous slider does not fit a menu item.

## Decision

1. **The Mac holds the brightness setting.** The companion stores it in UserDefaults and puts it at the end of the
   measurement line as `bri=<1-5>` every second (protocol v2 §4.4). The panel stores nothing (no NVS writes). No
   acknowledgement, retry or flash write is needed, and the setting has one source of truth. A rebooted panel is
   back to the chosen level with the next frame.
2. **A level (1–5) is sent, not a PWM value.** The panel decides what each level looks like. The backlight's
   properties (frequency, bits, curve) are the panel's business and stay out of the companion.
3. **The panel moves to 1 kHz / 14 bits and lights at `(percent/100)^2.2 × 16383`** (as the knowledge entry says).
   When the board is not a BASIC or `ledcChangeFrequency` fails, it passes the percentage proportionally to M5GFX's
   `setBrightness`. The percentages were chosen on the device (table below).
4. **Until the first frame the panel lights at level 3** (after boot, in setup mode, while waiting). The companion's
   default is level 3 too. The level received is kept in RAM until reboot (across sessions and after dimming).
5. **Dimming without data is unchanged** (off after 5 minutes, back on with a button or data — ADR-0001). Lighting
   up returns to the chosen level.
6. **The protocol becomes v2.** The panel announces `HELLO 2` and accepts only the v2 form. The companion connects to
   both versions 1 and 2 and sends the form of `HELLO`'s version. While connected to a version 1 panel the menu's
   brightness cannot be chosen and says the firmware needs updating. Key derivation and the frame label
   (`m5-system-panel/1`) are unchanged: only the measurement form changes, and rewriting the version (`HELLO` is not
   protected by the cipher) in either direction only ends the connection — the disruption accepted in §8.
7. **The menu has a "Brightness" submenu with five levels** ("1 (dark)" to "5 (bright)").

Level percentages (chosen on the device on 2026-10-05; one BASIC v2.7, one maintainer's judgement):

| Level | Percent | 14-bit value |
|---|---|---|
| 1 | 25% | 776 |
| 2 | 40% | 2182 |
| 3 | 55% | 4397 |
| 4 | 65% | 6350 |
| 5 | 75% | 8700 |

How: 10 / 30 / 50 / 75 / 100% first, judged "level 1 too dark, level 3 a little dark, level 4 (75%) is the most I
want and level 5 too bright". The second set, with the top at 75% and the bottom raised to 25%, was judged "all just
right, evenly spaced" (within ADR-023's "stop at the second on-device adjustment"). Full on (100%) cannot be chosen.

## Consequences

- Changing the brightness needs both the app and the firmware updated. The new app works with the old firmware
  (without the brightness); the old app with the new firmware reports "firmware does not match". The README states
  the update order.
- The brightness before a connection (boot, setup mode, waiting) cannot be chosen; it is level 3.
- Six bytes (` bri=3`) more per second. The longest plaintext is 530 bytes, within the 700-byte limit.
- Full on cannot be chosen (level 5 is 75%). If a bright room turns out to need more, revisit level 5 alone.
- When the move to 1 kHz / 14 bits succeeded, the light goes on and off through our own PWM writes, never `setBrightness`
  (which would write a 9-bit value). When it did not (including a BASIC where `ledcChangeFrequency` failed) the channel stays
  9-bit, and `setBrightness` is used.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Store it in the panel's NVS and send it only when changed | Adds acknowledgement, retry and save-failure handling, and two sources of truth. Having the chosen brightness before a connection is a small gain |
| Send a PWM value (0–255 or similar) | Leaks the panel's business (backlight frequency, curve) into the companion; changing the board or the way it is lit would change the app |
| A continuous slider | Does not fit a menu-style `MenuBarExtra`; it would need a window-style extra or a separate window, making the resident app heavier |
| A new message kind (`B bri=…`) | A v1 panel closes on an unknown kind, so the version must rise anyway; riding on every measurement keeps no state |
| Raise the label to `m5-system-panel/2` | Key and frame construction do not change. A version mismatch already only ends the connection; raising it would detect it slightly earlier and would regenerate the key and frame vectors |
| Change the brightness with the buttons | The buttons only switch pages (RFP §2); the maintainer asked for "a command from the companion" |
