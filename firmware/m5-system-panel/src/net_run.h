// Normal operation (protocol v2 §2, §4): join the saved Wi-Fi, advertise the
// service, accept connections and hand them to pp::SessionManager.
#pragma once

#include "config_store.h"
#include "display.h"

namespace net_run {

void begin(const StoredConfig& config, ui::Model* model);
// Once per loop: Wi-Fi state, accepts, lines, timeouts, acknowledgements.
// Returns true when readings arrived (the screen should be redrawn).
bool poll(uint32_t now_ms);
ui::WifiState wifi_state();

}  // namespace net_run
