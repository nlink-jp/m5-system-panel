// m5-system-panel firmware: shows one Mac's CPU, GPU, memory and network.
//
// Boot: holding B for 3 s erases the settings. No settings → setup mode (a
// temporary Wi-Fi with a one-time password; the companion finishes setup).
// Settings → join the home Wi-Fi, advertise over Bonjour, accept the paired
// Mac's session and draw. Buttons only switch pages: A previous, C next,
// B overview. See docs/ja/protocol.ja.md and the RFP.

#include <M5Unified.h>

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

ui::Model model;  // ~4 KB of history: kept off the stack
int page = 0;
bool backlight = true;
uint32_t last_history = 0;
uint32_t last_draw = 0;
bool dirty = true;

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
  M5.begin();
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
    if (!backlight) {
      backlight = true;
      ui::set_backlight(true);
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
  if (backlight && waited_long && !model.fresh(now)) {
    backlight = false;
    ui::set_backlight(false);
  } else if (!backlight && model.fresh(now)) {
    backlight = true;
    ui::set_backlight(true);
    dirty = true;
  }

  if (dirty && backlight && now - last_draw >= 100) {
    ui::draw(page, model, net_run::wifi_state(), now);
    last_draw = now;
    dirty = false;
  }
  delay(5);
}
