#include "net_run.h"

#include <ESPmDNS.h>
#include <WiFi.h>
#include <esp_random.h>
#include <stdio.h>
#include <string.h>

#include "panel_service.h"
#include "panel_sessions.h"

namespace net_run {
namespace {

constexpr uint32_t kJoinTimeoutMs = 30000;  // then "cannot connect" (retries continue)
constexpr int kSlots = pp::SessionManager::kSlots;

void random_bytes(uint8_t* out, size_t n) { esp_fill_random(out, n); }

WiFiServer server(PANEL_PORT);
WiFiClient clients[kSlots];
bool in_use[kSlots] = {};
pp::LineBuffer buffers[kSlots];
pp::SessionManager* sessions = nullptr;
ui::Model* model = nullptr;
ui::WifiState wifi = ui::WifiState::kConnecting;
uint32_t join_started = 0;
bool advertised = false;
uint32_t last_advertise_try = 0;
constexpr uint32_t kAdvertiseRetryMs = 5000;
char device_id[5] = {};

struct ClientSink : pp::Sink {
  void send(int slot, const char* line) override {
    if (!in_use[slot] || !clients[slot].connected()) return;
    // One write per line: a line and its LF as separate writes doubled the segments.
    char out[pp::kMaxLine + 2];
    const size_t n = strnlen(line, pp::kMaxLine);
    memcpy(out, line, n);
    out[n] = '\n';
    clients[slot].write(reinterpret_cast<const uint8_t*>(out), n + 1);
  }
  void close(int slot) override {
    clients[slot].stop();
    in_use[slot] = false;
  }
} sink;

void advertise() {
  char host[32], instance[32];
  snprintf(host, sizeof(host), "%s-%s", PANEL_SERVICE_NAME, device_id);
  snprintf(instance, sizeof(instance), "%s %s", PANEL_SERVICE_NAME, device_id);
  if (!MDNS.begin(host)) return;
  MDNS.setInstanceName(instance);
  MDNS.addService(PANEL_SERVICE_NAME, "tcp", PANEL_PORT);
  // String arguments: the char*/const char* overloads are ambiguous with mixed arrays.
  MDNS.addServiceTxt(String(PANEL_SERVICE_NAME), String("tcp"), String("v"), String(pp::kRunVersion));  // §2, §10
  MDNS.addServiceTxt(String(PANEL_SERVICE_NAME), String("tcp"), String("id"), String(device_id));
  advertised = true;
}

}  // namespace

void begin(const StoredConfig& config, ui::Model* m) {
  model = m;
  memcpy(device_id, config.device_id, 5);
  memcpy(model->device_id, config.device_id, 5);
  static pp::SessionManager manager(config.key, config.device_id, random_bytes);
  sessions = &manager;

  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  char ssid[33] = {};
  char password[64] = {};
  memcpy(ssid, config.ssid, config.ssid_length);  // an SSID with a NUL byte cannot be joined
  memcpy(password, config.password, config.password_length);
  WiFi.begin(ssid, config.password_length > 0 ? password : nullptr);
  memset(password, 0, sizeof(password));
  join_started = millis();
  server.begin();
  server.setNoDelay(true);
}

ui::WifiState wifi_state() { return wifi; }

bool poll(uint32_t now) {
  if (WiFi.status() == WL_CONNECTED) {
    wifi = ui::WifiState::kConnected;
    if (!advertised && (last_advertise_try == 0 || now - last_advertise_try >= kAdvertiseRetryMs)) {
      last_advertise_try = now;
      advertise();
    }
  } else {
    if (wifi == ui::WifiState::kConnected) join_started = now;  // lost: start counting again
    wifi = now - join_started >= kJoinTimeoutMs ? ui::WifiState::kFailed : ui::WifiState::kConnecting;
    if (advertised) {
      MDNS.end();
      advertised = false;
    }
  }

  WiFiClient incoming = server.accept();
  if (incoming) {
    const int slot = sessions->slot_for_accept(sink);
    if (slot < 0) {
      incoming.stop();
    } else {
      clients[slot] = incoming;
      clients[slot].setNoDelay(true);
      in_use[slot] = true;
      buffers[slot] = pp::LineBuffer();
      sessions->on_accept(slot, now, sink);
    }
  }

  bool got_readings = false;
  for (int slot = 0; slot < kSlots; ++slot) {
    if (!in_use[slot]) continue;
    WiFiClient& c = clients[slot];
    while (in_use[slot] && c.available()) {
      const int byte = c.read();
      if (byte < 0) break;
      const pp::LineBuffer::Result r = buffers[slot].push(static_cast<uint8_t>(byte));
      if (r == pp::LineBuffer::Result::kError) {
        sessions->on_closed(slot);
        sink.close(slot);
        break;
      }
      if (r != pp::LineBuffer::Result::kLine) continue;
      pp::Readings readings;
      if (sessions->on_line(slot, buffers[slot].line(), buffers[slot].length(), now, sink, &readings)) {
        model->latest = readings;
        model->latest_at = now;
        model->have_readings = true;
        got_readings = true;
      }
    }
    if (in_use[slot] && !c.connected()) {
      sessions->on_closed(slot);
      sink.close(slot);
    }
  }
  sessions->tick(now, sink);
  model->session = sessions->established();
  return got_readings;
}

}  // namespace net_run
