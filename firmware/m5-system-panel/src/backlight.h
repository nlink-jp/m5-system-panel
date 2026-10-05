// The backlight's brightness levels (ADR-0003). The companion sends a level
// (`bri`, 1..5); what each level looks like is decided here.
#pragma once

#include <stdint.h>

namespace backlight {

constexpr uint8_t kOff = 0;
constexpr uint8_t kLevels = 5;
constexpr uint8_t kDefaultLevel = 3;  // before the first frame (ADR-0003 decision 4)

// The share of full brightness per level, in percent. Chosen on the device
// (ADR-0003 table); the PWM duty applies a 2.2 power curve to it.
constexpr uint8_t kPercent[kLevels + 1] = {0, 25, 40, 55, 65, 75};

// 1 kHz, 14 bits on GPIO32 (knowledge embedded.md: the BASIC's backlight has no
// dark side at M5GFX's 44.1 kHz).
constexpr uint8_t kPin = 32;
constexpr uint32_t kFrequency = 1000;
constexpr uint8_t kBits = 14;
constexpr uint32_t kFull = (1u << kBits) - 1;  // 16383

// (percent/100)^2.2 x 16383, rounded; at least 1 count for any lit level.
uint32_t duty(uint8_t level);

// Moves M5GFX's channel to 1 kHz / 14 bits. Falls back to M5GFX's own
// setBrightness when the board is not a BASIC or the change fails.
void begin();
// kOff or 1..kLevels; anything else is treated as kDefaultLevel.
void set(uint8_t level);

}  // namespace backlight
