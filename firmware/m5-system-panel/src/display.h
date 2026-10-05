// What the panel shows. Drawing goes through one 320x80 16-bit band (51,200 B)
// pushed three times per frame: with no PSRAM a full-screen buffer cannot be
// allocated once Wi-Fi runs (ADR-0001 decision 2).
#pragma once

#include <stdint.h>

#include "panel_protocol.h"

namespace ui {

constexpr int kPages = 5;  // overview, CPU, GPU, memory, network (RFP amendment A5)
constexpr int kHistory = 300;                    // one point per second, ~5 minutes
constexpr uint32_t kStaleAfterMs = 3000;         // "waiting for data" (RFP §2)
constexpr uint32_t kDimAfterMs = 5 * 60 * 1000;  // then the backlight goes off

// One second of history; kGap marks a second without data.
constexpr int16_t kGap = -1;

struct Model {
  char device_id[5] = "----";
  bool have_readings = false;
  pp::Readings latest = {};
  uint32_t latest_at = 0;
  bool session = false;  // an established, verified session
  // History, oldest first, advanced once a second by tick_history().
  int16_t cpu[kHistory];   // tenths of a percent
  int16_t gpu[kHistory];
  int16_t mem[kHistory];   // tenths of a percent of total
  int32_t rx[kHistory];    // bytes/s, clamped to int32; -1 = gap
  int32_t tx[kHistory];
  Model();
  void tick_history(uint32_t now_ms);
  bool fresh(uint32_t now_ms) const { return have_readings && now_ms - latest_at < kStaleAfterMs; }
};

enum class WifiState { kConnecting, kConnected, kFailed };

// Also starts the backlight at its default level (backlight.h).
void begin();

// Full-screen states outside normal operation.
void show_boot_hold(int seconds_left);
void show_message(const char* title, const char* body);
void show_setup(const char* ssid, const char* password, const char* status);

// Normal operation: draws `page` (0..kPages-1) from the model.
void draw(int page, const Model& model, WifiState wifi, uint32_t now_ms);

}  // namespace ui
