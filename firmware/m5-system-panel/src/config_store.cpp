#include "config_store.h"

#include <Preferences.h>
#include <string.h>

#include "mbedtls/platform_util.h"

namespace config_store {
namespace {

constexpr const char* kNamespace = "m5sp";
constexpr uint8_t kVersion = 1;

}  // namespace

bool load(StoredConfig* out) {
  Preferences prefs;
  if (!prefs.begin(kNamespace, true)) return false;
  StoredConfig c = {};
  bool ok = prefs.getUChar("v", 0) == kVersion;
  if (ok) {
    const size_t ssid = prefs.getBytes("ssid", c.ssid, sizeof(c.ssid));
    const size_t pass = prefs.getBytesLength("pass") == 0 ? 0 : prefs.getBytes("pass", c.password, sizeof(c.password));
    const size_t id = prefs.getBytes("id", c.device_id, 4);
    const size_t key = prefs.getBytes("key", c.key, sizeof(c.key));
    ok = ssid >= 1 && ssid <= 32 && pass <= 63 && id == 4 && key == pp::kKeyBytes &&
         pp::is_device_id(c.device_id, 4);
    c.ssid_length = static_cast<uint8_t>(ssid);
    c.password_length = static_cast<uint8_t>(pass);
    c.device_id[4] = '\0';
  }
  prefs.end();
  if (ok) *out = c;
  mbedtls_platform_zeroize(&c, sizeof(c));
  return ok;
}

bool save(const pp::Commit& commit) {
  Preferences prefs;
  if (!prefs.begin(kNamespace, false)) return false;
  prefs.clear();
  bool ok = prefs.putBytes("ssid", commit.network.ssid, commit.network.ssid_length) == commit.network.ssid_length &&
            prefs.putBytes("id", commit.device_id, 4) == 4 &&
            prefs.putBytes("key", commit.key, pp::kKeyBytes) == pp::kKeyBytes;
  if (ok && commit.network.password_length > 0) {
    ok = prefs.putBytes("pass", commit.network.password, commit.network.password_length) ==
         commit.network.password_length;
  }
  if (ok) ok = prefs.putUChar("v", kVersion) == 1;  // last: marks the set complete
  prefs.end();
  return ok;
}

void erase() {
  Preferences prefs;
  if (prefs.begin(kNamespace, false)) {
    prefs.clear();
    prefs.end();
  }
}

}  // namespace config_store
