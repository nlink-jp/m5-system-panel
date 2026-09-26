// m5-system-panel firmware — scaffold.
//
// Shows the name and version so that a flashed board can be identified. Wi-Fi,
// discovery, the wire format and the pages come in Phase 1 (see the RFP).

#include <M5Unified.h>

#include "src/panel_service.h"

void setup() {
  M5.begin();
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
  M5.Display.setTextDatum(middle_center);
  M5.Display.setFont(&fonts::Font4);
  M5.Display.drawString(PANEL_SERVICE_NAME, M5.Display.width() / 2, M5.Display.height() / 2 - 16);
  M5.Display.setFont(&fonts::Font2);
  M5.Display.drawString(FW_VERSION, M5.Display.width() / 2, M5.Display.height() / 2 + 16);
}

void loop() {
  M5.update();
  delay(20);
}
