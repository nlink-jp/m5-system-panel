#include "backlight.h"

#include <M5Unified.h>
#include <math.h>

namespace backlight {
namespace {

static_assert(kPercent[0] == 0 && kPercent[kLevels] <= 100, "off is 0, the top at most full");
constexpr bool rising(int i) { return i > kLevels || (kPercent[i - 1] < kPercent[i] && rising(i + 1)); }
static_assert(rising(1), "each level is brighter than the one below it");

bool fine_pwm = false;  // our 1 kHz / 14-bit channel, or M5GFX's setBrightness

}  // namespace

uint32_t duty(uint8_t level) {
  if (level == kOff || level > kLevels) return 0;
  const double share = pow(kPercent[level] / 100.0, 2.2);
  const uint32_t d = static_cast<uint32_t>(lround(share * kFull));
  return d == 0 ? 1 : d;
}

void begin() {
  // M5GFX 0.2.27 attaches GPIO32 with ledcAttach on arduino-esp32 3.x, so the
  // pin addresses its channel (Light_PWM.cpp).
  fine_pwm = M5.getBoard() == m5::board_t::board_M5Stack && ledcChangeFrequency(kPin, kFrequency, kBits) != 0;
}

void set(uint8_t level) {
  if (level > kLevels) level = kDefaultLevel;
  if (fine_pwm) {
    ledcWrite(kPin, duty(level));
  } else {
    M5.Display.setBrightness(static_cast<uint8_t>(kPercent[level] * 255 / 100));
  }
}

}  // namespace backlight
