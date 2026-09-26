// The panel's saved settings: home Wi-Fi, device ID and key (protocol v1 §5.2).
//
// One NVS namespace, written only when a setup session reaches STORED. The
// Wi-Fi driver's own credential storage is turned off (WiFi.persistent(false)),
// so this is the only place they live; erasing it forgets everything.
// NVS is not encrypted (RFP §7): the key and password are plaintext in flash.
#pragma once

#include <stdint.h>

#include "panel_sessions.h"

struct StoredConfig {
  uint8_t ssid[32];
  uint8_t ssid_length;
  uint8_t password[63];
  uint8_t password_length;  // 0: no authentication
  char device_id[5];        // 4 characters and a NUL
  uint8_t key[pp::kKeyBytes];
};

namespace config_store {

// False when nothing complete is saved.
bool load(StoredConfig* out);
// Writes the commit; the version marker goes last, so a torn write reads as "nothing saved".
bool save(const pp::Commit& commit);
void erase();

}  // namespace config_store
