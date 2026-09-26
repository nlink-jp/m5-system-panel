#include "net_setup.h"

#include <M5Unified.h>
#include <WiFi.h>
#include <esp_random.h>
#include <stdio.h>
#include <string.h>

#include "config_store.h"
#include "display.h"
#include "panel_service.h"
#include "panel_sessions.h"

namespace net_setup {
namespace {

void random_bytes(uint8_t* out, size_t n) { esp_fill_random(out, n); }

// Unbiased pick from an alphabet without look-alikes (§5.3). Only after the
// radio is up: the RNG is a true RNG while Wi-Fi runs (ADR-0001 decision 5).
void make_password(char out[13]) {
  static const char kAlphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
  const uint32_t n = sizeof(kAlphabet) - 1;
  const uint32_t limit = UINT32_MAX - (UINT32_MAX % n);
  for (int i = 0; i < 12; ++i) {
    uint32_t r;
    do r = esp_random(); while (r >= limit);
    out[i] = kAlphabet[r % n];
  }
  out[12] = '\0';
}

void make_device_id(char out[5]) {
  static const char kHex[] = "0123456789ABCDEF";
  const uint32_t r = esp_random();
  for (int i = 0; i < 4; ++i) out[i] = kHex[(r >> (4 * i)) & 0xF];
  out[4] = '\0';
}

pp::Auth auth_of(wifi_auth_mode_t mode) {
  switch (mode) {
    case WIFI_AUTH_OPEN: return pp::Auth::kOpen;
    case WIFI_AUTH_WPA2_PSK: return pp::Auth::kWpa2;
    case WIFI_AUTH_WPA3_PSK: return pp::Auth::kWpa3;
    case WIFI_AUTH_WPA2_WPA3_PSK: return pp::Auth::kWpa2Wpa3;
    default: return pp::Auth::kOther;
  }
}

struct ClientSink : pp::Sink {
  WiFiClient* client = nullptr;
  bool closed = false;
  void send(int, const char* line) override {
    if (client == nullptr || !client->connected()) return;
    client->print(line);
    client->print('\n');
  }
  void close(int) override {
    if (client != nullptr) client->stop();
    closed = true;
  }
};

}  // namespace

void run() {
  WiFi.persistent(false);  // the driver never stores credentials (config_store does)
  WiFi.mode(WIFI_STA);     // radio on: scan first, and the RNG becomes a true RNG
  ui::show_message("設定の準備", "周辺の Wi-Fi を探しています");

  static pp::ScanEntry raw[40];
  static pp::ScanEntry networks[20];
  const int found = WiFi.scanNetworks();
  size_t raw_count = 0;
  for (int i = 0; i < found && raw_count < 40; ++i) {
    pp::ScanEntry& e = raw[raw_count++];
    const String ssid = WiFi.SSID(i);
    e.ssid_length = static_cast<uint8_t>(ssid.length() > 32 ? 32 : ssid.length());
    memcpy(e.ssid, ssid.c_str(), e.ssid_length);
    e.rssi = static_cast<int16_t>(WiFi.RSSI(i));
    e.auth = auth_of(WiFi.encryptionType(i));
  }
  WiFi.scanDelete();
  const size_t network_count = pp::prepare_scan(raw, raw_count, networks, 20);

  char device_id[5];
  char password[13];
  make_device_id(device_id);
  make_password(password);
  char ssid[40];
  snprintf(ssid, sizeof(ssid), "%s-%s", PANEL_SERVICE_NAME, device_id);

  WiFi.mode(WIFI_AP);
  if (!WiFi.softAP(ssid, password)) {
    ui::show_message("設定用 Wi-Fi を出せません", "電源を入れ直してください");
    for (;;) delay(1000);
  }
  WiFiServer server(PANEL_PORT);
  server.begin();
  server.setNoDelay(true);
  ui::show_setup(ssid, password, "接続を待っています");

  static pp::SetupServer setup;
  setup.begin(device_id, networks, network_count, random_bytes);
  WiFiClient client;
  ClientSink sink;
  pp::LineBuffer buffer;
  bool active = false;

  for (;;) {
    M5.update();
    const uint32_t now = millis();
    WiFiClient incoming = server.accept();
    if (incoming) {
      if (active && client.connected()) {
        incoming.stop();  // one setup session at a time (§5.2)
      } else {
        client = incoming;
        client.setNoDelay(true);
        sink.client = &client;
        sink.closed = false;
        buffer = pp::LineBuffer();
        active = true;
        setup.on_connect(now, sink, 0);
        ui::show_setup(ssid, password, "コンパニオンと接続しました");
      }
    }
    if (active) {
      while (client.connected() && client.available() && !sink.closed) {
        const int c = client.read();
        if (c < 0) break;
        const pp::LineBuffer::Result r = buffer.push(static_cast<uint8_t>(c));
        if (r == pp::LineBuffer::Result::kError) {
          sink.close(0);
          break;
        }
        if (r != pp::LineBuffer::Result::kLine) continue;
        const pp::SetupServer::Result result = setup.on_line(buffer.line(), buffer.length(), now, sink, 0);
        if (result == pp::SetupServer::Result::kCommit) {
          ui::show_setup(ssid, password, "保存しています");
          if (config_store::save(setup.commit())) {
            setup.done(sink, 0);
            client.flush();
            delay(500);
            ui::show_message("設定を保存しました", "再起動します");
            delay(1000);
            ESP.restart();
          }
          ui::show_setup(ssid, password, "保存に失敗しました。やり直してください");
          sink.close(0);
        }
      }
      if (setup.idle(now)) sink.close(0);
      if (sink.closed || !client.connected()) {
        client.stop();
        setup.on_closed();
        active = false;
        ui::show_setup(ssid, password, "接続を待っています");
      }
    }
    delay(5);
  }
}

}  // namespace net_setup
