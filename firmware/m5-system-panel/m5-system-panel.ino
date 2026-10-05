// m5-system-panel firmware: shows one Mac's CPU, GPU, memory and network.
//
// Boot: holding B for 3 s erases the settings. No settings → setup mode (a
// temporary Wi-Fi with a one-time password; the companion finishes setup).
// Settings → join the home Wi-Fi, advertise over Bonjour, accept the paired
// Mac's session and draw. Buttons only switch pages: A previous, C next,
// B overview. The brightness level comes with every frame from the companion
// (ADR-0003). See docs/ja/protocol.ja.md and the RFP.

#include <M5Unified.h>

#include "src/backlight.h"
#include "src/config_store.h"
#include "src/display.h"
#include "src/net_run.h"
#include "src/net_setup.h"
#include "src/panel_service.h"

// The protocol code keeps its buffers on the stack (~3 KB per line); the
// default 8 KB loop task is not enough (measured in firmware/protocol-test).
SET_LOOP_TASK_STACK_SIZE(16 * 1024);

namespace {

constexpr uint32_t kEraseHoldMs = 3000;
constexpr uint32_t kWokenHoldMs = 30000;  // a button lit the screen: keep it lit this long

ui::Model model;  // ~4 KB of history: kept off the stack
int page = 0;
bool lit = true;
// The last level the companion sent; kept until reboot, also across sessions and dimming.
uint8_t level = backlight::kDefaultLevel;
uint32_t last_history = 0;
uint32_t last_draw = 0;
bool dirty = true;
uint32_t woken_at = 0;  // when a button last lit a dark screen

// True when B was held for the whole countdown.
bool erase_requested() {
  M5.update();
  if (!M5.BtnB.isPressed()) return false;
  const uint32_t start = millis();
  int shown = -1;
  while (M5.BtnB.isPressed()) {
    const uint32_t held = millis() - start;
    if (held >= kEraseHoldMs) return true;
    const int left = static_cast<int>((kEraseHoldMs - held + 999) / 1000);
    if (left != shown) {
      ui::show_boot_hold(left);
      shown = left;
    }
    delay(20);
    M5.update();
  }
  return false;
}

}  // namespace

void setup() {
  // No sound is ever played. With internal_spk on (the default) M5Unified drives
  // the speaker pin (GPIO25) low during begin() — a step on the amplifier input,
  // a suspected cause of the pop heard at boot. Leave the pin alone.
  auto m5_config = M5.config();
  m5_config.internal_spk = false;
  M5.begin(m5_config);
  ui::begin();
  ui::show_message(PANEL_SERVICE_NAME, FW_VERSION);

  if (erase_requested()) {
    config_store::erase();
    ui::show_message("設定を消去しました", "設定モードに入ります");
    delay(1000);
  }
  static StoredConfig config;
  if (!config_store::load(&config)) {
    net_setup::run();  // restarts when done
  }
  net_run::begin(config, &model);
}

void loop() {
  M5.update();
  const uint32_t now = millis();
  if (net_run::poll(now)) dirty = true;

  // Buttons: the first press on a dark screen only wakes it.
  const bool a = M5.BtnA.wasPressed(), b = M5.BtnB.wasPressed(), c = M5.BtnC.wasPressed();
  if (a || b || c) {
    woken_at = now == 0 ? 1 : now;  // any press keeps a stale screen lit for a while
    if (!lit) {
      lit = true;
      backlight::set(level);
    } else if (a) {
      page = (page + ui::kPages - 1) % ui::kPages;
    } else if (c) {
      page = (page + 1) % ui::kPages;
    } else {
      page = 0;
    }
    dirty = true;
  }

  if (now - last_history >= 1000) {
    last_history = now;
    model.tick_history(now);
    dirty = true;
  }

  // Dark after a long wait for data (the Mac asleep keeps USB power on: ADR-0001).
  const bool waited_long = !model.have_readings ? now > ui::kDimAfterMs : now - model.latest_at >= ui::kDimAfterMs;
  const bool woken = woken_at != 0 && now - woken_at < kWokenHoldMs;
  if (lit && waited_long && !model.fresh(now) && !woken) {
    lit = false;
    backlight::set(backlight::kOff);
  } else if (!lit && model.fresh(now)) {
    lit = true;
    backlight::set(level);
    dirty = true;
  }
  // A new level from the companion takes effect at once on a lit screen.
  if (model.have_readings && model.latest.brightness != level) {
    level = model.latest.brightness;
    if (lit) backlight::set(level);
  }

  if (dirty && lit && now - last_draw >= 100) {
    ui::draw(page, model, net_run::wifi_state(), now);
    last_draw = now;
    dirty = false;
  }
  delay(5);
}
