// Phase 0 probe firmware (RFP §4). Not the product: no encryption, no setup
// exchange. It exists to observe what the documentation does not state.
//
//   normal boot     STA: join the Wi-Fi in wifi_local.h, advertise
//                   _m5-system-panel._tcp, accept one TCP client, answer every
//                   second with an "ack" line carrying the panel's own counters
//                   (items 1, 3, 4, 5).
//   hold B at boot  AP: scan once, generate a one-time password after the radio
//                   is up, start the setup SoftAP, show name and password
//                   (items 1, 2).
//
// Every observation the Mac needs travels in the ack line, so no serial monitor
// is opened during the tests (opening the port can reset the ESP32).

#include <ESPmDNS.h>
#include <M5Unified.h>
#include <WiFi.h>
#include <esp_random.h>

#include "wifi_local.h"  // WIFI_SSID, WIFI_PASS — gitignored; see wifi_local.h.example

static const uint16_t kPort = 47110;
static const char *kService = "m5-system-panel";

static WiFiServer server(kPort);
static WiFiClient client;
static M5Canvas canvas(&M5.Display);

static bool apMode = false;
static char deviceId[5];
static char apSsid[32];
static char apPass[13];

static uint32_t accepted = 0;   // connections accepted
static uint32_t replaced = 0;   // connections dropped because a newer one arrived
static uint32_t linesIn = 0;    // lines received on the current connection
static uint32_t ackSeq = 0;
static uint32_t lastAckMs = 0;
static uint32_t lastDrawMs = 0;
static volatile uint32_t apStations = 0;
static char lastEvent[48] = "boot";
static char lineBuf[160];
static size_t lineLen = 0;

static uint32_t heapAtBoot, heapAfterWifi, heapAfterSprite;
static bool fullSpriteOk = false;

static void setEvent(const char *e) {
  snprintf(lastEvent, sizeof(lastEvent), "%lu:%s", (unsigned long)(millis() / 1000), e);
}

static void onWifiEvent(arduino_event_id_t event) {
  switch (event) {
    case ARDUINO_EVENT_WIFI_AP_STACONNECTED: apStations++; setEvent("ap-sta-join"); break;
    case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED: if (apStations) apStations--; setEvent("ap-sta-leave"); break;
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED: setEvent("sta-disconnected"); break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP: setEvent("sta-got-ip"); break;
    default: break;
  }
}

// Unbiased pick from an alphabet without look-alike characters. Called only
// after the radio is up: the RNG is a true RNG only while Wi-Fi or Bluetooth
// is enabled (ESP-IDF v5.5, Random Number Generation).
static void makePassword(char *out, size_t len) {
  static const char kAlphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
  const uint32_t n = sizeof(kAlphabet) - 1;
  const uint32_t limit = UINT32_MAX - (UINT32_MAX % n);
  for (size_t i = 0; i < len; i++) {
    uint32_t r;
    do { r = esp_random(); } while (r >= limit);
    out[i] = kAlphabet[r % n];
  }
  out[len] = '\0';
}

static void drawStatus() {
  canvas.fillSprite(TFT_BLACK);
  canvas.setCursor(0, 0);
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  if (apMode) {
    canvas.printf("SETUP AP  id %s  stations %lu\n", deviceId, (unsigned long)apStations);
  } else {
    canvas.printf("STA %s  id %s\n", WiFi.localIP().toString().c_str(), deviceId);
    canvas.printf("client %s  in %lu  acc %lu  repl %lu\n", client.connected() ? "yes" : "no",
                  (unsigned long)linesIn, (unsigned long)accepted, (unsigned long)replaced);
  }
  canvas.printf("heap %lu  min %lu  big %lu\n", (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getMinFreeHeap(), (unsigned long)ESP.getMaxAllocHeap());
  canvas.printf("ev %s", lastEvent);
  canvas.pushSprite(0, 160);
}

static void startAp() {
  WiFi.mode(WIFI_STA);  // radio on: the scan runs first, and the RNG becomes a true RNG
  int found = WiFi.scanNetworks();
  makePassword(apPass, 12);
  snprintf(apSsid, sizeof(apSsid), "%s-%s", kService, deviceId);
  WiFi.mode(WIFI_AP);
  bool ok = WiFi.softAP(apSsid, apPass);
  setEvent(ok ? "ap-up" : "ap-failed");

  M5.Display.fillRect(0, 0, 320, 160, TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
  M5.Display.setFont(&fonts::Font2);
  M5.Display.setCursor(0, 0);
  M5.Display.printf("Phase 0 setup AP (scan found %d)\n", found);
  M5.Display.printf("IP %s\n\n", WiFi.softAPIP().toString().c_str());
  M5.Display.setFont(&fonts::Font4);
  M5.Display.println(apSsid);
  M5.Display.println(apPass);
  M5.Display.setFont(&fonts::Font0);
}

static void startSta() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) delay(100);
  setEvent(WiFi.status() == WL_CONNECTED ? "sta-up" : "sta-timeout");

  char host[40];
  snprintf(host, sizeof(host), "%s-%s", kService, deviceId);
  MDNS.begin(host);
  char instance[40];
  snprintf(instance, sizeof(instance), "%s %s", kService, deviceId);
  MDNS.setInstanceName(instance);
  MDNS.addService(kService, "tcp", kPort);
  MDNS.addServiceTxt(kService, "tcp", "id", deviceId);
  MDNS.addServiceTxt(kService, "tcp", "mode", "phase0");
  server.begin();

  M5.Display.fillRect(0, 0, 320, 160, TFT_BLACK);
  M5.Display.setCursor(0, 0);
  M5.Display.setFont(&fonts::Font2);
  M5.Display.printf("Phase 0 STA  %s\nport %u  service _%s._tcp\n", host, kPort, kService);
  M5.Display.setFont(&fonts::Font0);
}

void setup() {
  M5.begin();
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  heapAtBoot = ESP.getFreeHeap();

  uint64_t mac = ESP.getEfuseMac();
  snprintf(deviceId, sizeof(deviceId), "%04X", (unsigned)((mac >> 32) & 0xFFFF));

  M5.update();
  apMode = M5.BtnB.isPressed();
  WiFi.persistent(false);  // never let the driver write credentials to NVS
  WiFi.onEvent(onWifiEvent);

  if (apMode) startAp(); else startSta();
  heapAfterWifi = ESP.getFreeHeap();

  // Item 1: can a full-screen 16-bit buffer coexist with Wi-Fi? Try, record,
  // release, then keep the small status strip the probe actually uses.
  fullSpriteOk = canvas.createSprite(320, 240) != nullptr;
  canvas.deleteSprite();
  canvas.setColorDepth(16);
  canvas.createSprite(320, 80);
  canvas.setFont(&fonts::Font0);
  heapAfterSprite = ESP.getFreeHeap();
}

static void acceptClient() {
  WiFiClient incoming = server.accept();
  if (!incoming) return;
  if (client && client.connected()) {
    client.stop();
    replaced++;
    setEvent("replaced");
  } else {
    setEvent("accepted");
  }
  client = incoming;
  client.setNoDelay(true);
  accepted++;
  linesIn = 0;
  lineLen = 0;
}

static void readClient() {
  while (client && client.available()) {
    int c = client.read();
    if (c < 0) break;
    if (c == '\n') {
      linesIn++;
      lineLen = 0;
    } else if (lineLen < sizeof(lineBuf) - 1) {
      lineBuf[lineLen++] = (char)c;
    }
  }
}

static void sendAck() {
  if (!client || !client.connected()) return;
  client.printf("ack seq=%lu up=%lu heap=%lu min=%lu big=%lu boot=%lu wifi=%lu sprite=%lu full=%d "
                "acc=%lu repl=%lu in=%lu rssi=%d ev=%s\n",
                (unsigned long)ackSeq++, (unsigned long)millis(), (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getMinFreeHeap(), (unsigned long)ESP.getMaxAllocHeap(),
                (unsigned long)heapAtBoot, (unsigned long)heapAfterWifi, (unsigned long)heapAfterSprite,
                fullSpriteOk ? 1 : 0, (unsigned long)accepted, (unsigned long)replaced,
                (unsigned long)linesIn, WiFi.RSSI(), lastEvent);
}

void loop() {
  M5.update();
  uint32_t now = millis();
  if (!apMode) {
    acceptClient();
    readClient();
    if (now - lastAckMs >= 1000) {
      lastAckMs = now;
      sendAck();
    }
  }
  if (now - lastDrawMs >= 1000) {
    lastDrawMs = now;
    drawStatus();
  }
  delay(5);
}
