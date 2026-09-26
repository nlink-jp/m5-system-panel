#include "display.h"

#include <M5Unified.h>
#include <stdio.h>
#include <string.h>

#include "panel_service.h"

namespace ui {
namespace {

constexpr int kWidth = 320;
constexpr int kBand = 80;
constexpr int kHeader = 20;

M5Canvas band(&M5.Display);
bool band_ok = false;

const uint16_t kBg = TFT_BLACK;
const uint16_t kFg = TFT_WHITE;
const uint16_t kDim = 0x7BEF;       // grey
const uint16_t kCpuColor = 0x07FF;  // cyan
const uint16_t kGpuColor = 0xFD20;  // orange
const uint16_t kMemColor = 0x07E0;  // green
const uint16_t kRxColor = 0x5DFF;   // light blue
const uint16_t kTxColor = 0xFBE0;   // yellowish

// Every drawing call below uses screen coordinates; the band is offset by `y0`.
struct Pen {
  int y0;
  void text(const char* s, int x, int y, const lgfx::IFont* font, uint16_t color, textdatum_t datum = top_left) {
    band.setFont(font);
    band.setTextColor(color, kBg);
    band.setTextDatum(datum);
    band.drawString(s, x, y - y0);
  }
  void rect(int x, int y, int w, int h, uint16_t color) { band.fillRect(x, y - y0, w, h, color); }
  void frame(int x, int y, int w, int h, uint16_t color) { band.drawRect(x, y - y0, w, h, color); }
  void line(int x0, int y0s, int x1, int y1, uint16_t color) { band.drawLine(x0, y0s - y0, x1, y1 - y0, color); }
};

void format_percent(char* out, size_t n, int tenths) { snprintf(out, n, "%d.%d%%", tenths / 10, tenths % 10); }

// SI units, as Finder and Activity Monitor count network rates.
void format_rate(char* out, size_t n, uint64_t bytes_per_second) {
  const double v = static_cast<double>(bytes_per_second);
  if (v < 1000) snprintf(out, n, "%.0f B/s", v);
  else if (v < 1e6) snprintf(out, n, "%.1f KB/s", v / 1e3);
  else if (v < 1e9) snprintf(out, n, "%.1f MB/s", v / 1e6);
  else snprintf(out, n, "%.2f GB/s", v / 1e9);
}

// RAM in binary gigabytes, labelled "GB" as macOS does.
void format_gb(char* out, size_t n, uint64_t bytes) { snprintf(out, n, "%.1f", static_cast<double>(bytes) / 1073741824.0); }

// A line graph of `values` (oldest first) into the box; kGap breaks the line.
void graph16(Pen& p, const int16_t* values, int count, int x, int y, int w, int h, int max_value, uint16_t color) {
  p.frame(x, y, w, h, kDim);
  const int first = count > w ? count - w : 0;
  int px = -1, py = 0;
  for (int i = first; i < count; ++i) {
    const int gx = x + (w - (count - first)) + (i - first);
    if (values[i] < 0) {
      px = -1;
      continue;
    }
    const int v = values[i] > max_value ? max_value : values[i];
    const int gy = y + h - 1 - (v * (h - 2)) / max_value;
    if (px >= 0) p.line(px, py, gx, gy, color);
    px = gx;
    py = gy;
  }
}

void graph32(Pen& p, const int32_t* values, int count, int x, int y, int w, int h, int32_t max_value, uint16_t color) {
  p.frame(x, y, w, h, kDim);
  const int first = count > w ? count - w : 0;
  int px = -1, py = 0;
  for (int i = first; i < count; ++i) {
    const int gx = x + (w - (count - first)) + (i - first);
    if (values[i] < 0) {
      px = -1;
      continue;
    }
    const int64_t v = values[i] > max_value ? max_value : values[i];
    const int gy = y + h - 1 - static_cast<int>((v * (h - 2)) / max_value);
    if (px >= 0) p.line(px, py, gx, gy, color);
    px = gx;
    py = gy;
  }
}

// A scale that is a round number above the largest value (at least 10 KB/s).
int32_t network_scale(const Model& m, int window) {
  int32_t peak = 10000;
  for (int i = kHistory - window; i < kHistory; ++i) {
    if (m.rx[i] > peak) peak = m.rx[i];
    if (m.tx[i] > peak) peak = m.tx[i];
  }
  int32_t scale = 10000;
  while (scale < peak && scale < 1000000000) scale = scale * 10 / 5 >= peak ? scale * 2 : scale * 10;
  return scale;
}

void draw_header(Pen& p, int page, const Model& m, WifiState wifi) {
  static const char* const kTitles[kPages] = {"概要", "CPU", "GPU・メモリ", "ネットワーク"};
  p.rect(0, 0, kWidth, kHeader, 0x18E3);
  p.text(kTitles[page], 4, 2, &fonts::lgfxJapanGothicP_16, kFg);
  char right[32];
  snprintf(right, sizeof(right), "%s  %d/%d", m.device_id, page + 1, kPages);
  p.text(right, kWidth - 4, 3, &fonts::Font2, kFg, top_right);
  const uint16_t dot = wifi == WifiState::kConnected ? (m.session ? TFT_GREEN : TFT_YELLOW) : TFT_RED;
  band.fillCircle(kWidth - 88, 10 - p.y0, 4, dot);
}

void draw_overview(Pen& p, const Model& m) {
  const pp::Readings& r = m.latest;
  char a[32], b[32];
  // Quadrants: CPU | GPU / MEM | NET.
  struct Quad { int x, y; };
  const Quad q[4] = {{0, 20}, {160, 20}, {0, 130}, {160, 130}};
  for (int i = 0; i < 4; ++i) p.frame(q[i].x, q[i].y, 160, 110, 0x2104);

  p.text("CPU", q[0].x + 6, q[0].y + 4, &fonts::Font2, kCpuColor);
  format_percent(a, sizeof(a), r.cpu_tenths);
  p.text(a, q[0].x + 154, q[0].y + 22, &fonts::Font4, kFg, top_right);
  graph16(p, m.cpu, kHistory, q[0].x + 6, q[0].y + 56, 148, 48, 1000, kCpuColor);

  p.text("GPU", q[1].x + 6, q[1].y + 4, &fonts::Font2, kGpuColor);
  if (r.gpu_present) {
    format_percent(a, sizeof(a), r.gpu_tenths);
    p.text(a, q[1].x + 154, q[1].y + 22, &fonts::Font4, kFg, top_right);
    graph16(p, m.gpu, kHistory, q[1].x + 6, q[1].y + 56, 148, 48, 1000, kGpuColor);
  } else {
    p.text("取得できません", q[1].x + 80, q[1].y + 50, &fonts::lgfxJapanGothicP_16, kDim, top_center);
  }

  p.text("MEM", q[2].x + 6, q[2].y + 4, &fonts::Font2, kMemColor);
  format_gb(a, sizeof(a), r.mem_used);
  format_gb(b, sizeof(b), r.mem_total);
  char mem[48];
  snprintf(mem, sizeof(mem), "%s/%s GB", a, b);
  p.text(mem, q[2].x + 154, q[2].y + 26, &fonts::Font2, kFg, top_right);
  graph16(p, m.mem, kHistory, q[2].x + 6, q[2].y + 56, 148, 48, 1000, kMemColor);

  p.text("NET", q[3].x + 6, q[3].y + 4, &fonts::Font2, kRxColor);
  format_rate(a, sizeof(a), r.rx);
  format_rate(b, sizeof(b), r.tx);
  char down[40], up[40];
  snprintf(down, sizeof(down), "v %s", a);
  snprintf(up, sizeof(up), "^ %s", b);
  p.text(down, q[3].x + 154, q[3].y + 18, &fonts::Font2, kRxColor, top_right);
  p.text(up, q[3].x + 154, q[3].y + 34, &fonts::Font2, kTxColor, top_right);
  const int32_t scale = network_scale(m, 148);
  graph32(p, m.rx, kHistory, q[3].x + 6, q[3].y + 56, 148, 48, scale, kRxColor);
  graph32(p, m.tx, kHistory, q[3].x + 6, q[3].y + 56, 148, 48, scale, kTxColor);
}

void draw_cpu(Pen& p, const Model& m) {
  const pp::Readings& r = m.latest;
  char a[32];
  format_percent(a, sizeof(a), r.cpu_tenths);
  p.text("全体", 10, 26, &fonts::lgfxJapanGothicP_16, kDim);
  p.text(a, 310, 24, &fonts::Font4, kFg, top_right);
  graph16(p, m.cpu, kHistory, 10, 52, 300, 90, 1000, kCpuColor);
  p.text("コアごと", 10, 150, &fonts::lgfxJapanGothicP_16, kDim);
  const int n = r.core_count;
  if (n == 0) return;
  const int area = 300, gap = n > 32 ? 1 : 2;
  const int w = (area - gap * (n - 1)) / n;
  for (int i = 0; i < n; ++i) {
    const int x = 10 + i * (w + gap);
    const int h = (r.cores[i] * 62) / 100;
    p.frame(x, 172, w, 64, 0x2104);
    p.rect(x, 172 + 63 - h, w, h, kCpuColor);
  }
}

void draw_gpu_memory(Pen& p, const Model& m) {
  const pp::Readings& r = m.latest;
  char a[48], b[32], c[32];
  p.text("GPU", 10, 26, &fonts::Font2, kGpuColor);
  if (r.gpu_present) {
    format_percent(a, sizeof(a), r.gpu_tenths);
    p.text(a, 310, 24, &fonts::Font4, kFg, top_right);
    graph16(p, m.gpu, kHistory, 10, 50, 300, 64, 1000, kGpuColor);
  } else {
    p.text("この Mac では取得できません", 160, 70, &fonts::lgfxJapanGothicP_16, kDim, top_center);
  }
  // Memory: a stacked bar of app / wired / compressed against the installed amount.
  p.text("メモリ", 10, 124, &fonts::lgfxJapanGothicP_16, kMemColor);
  format_gb(b, sizeof(b), r.mem_used);
  format_gb(c, sizeof(c), r.mem_total);
  snprintf(a, sizeof(a), "%s / %s GB", b, c);
  p.text(a, 310, 126, &fonts::Font2, kFg, top_right);
  const int bar_x = 10, bar_y = 148, bar_w = 300, bar_h = 26;
  p.frame(bar_x, bar_y, bar_w, bar_h, kDim);
  if (r.mem_total > 0) {
    const uint64_t parts[3] = {r.mem_app, r.mem_wired, r.mem_compressed};
    const uint16_t colors[3] = {kMemColor, 0xFFE0, 0xF81F};
    int x = bar_x + 1;
    for (int i = 0; i < 3; ++i) {
      int w = static_cast<int>(static_cast<double>(parts[i]) / static_cast<double>(r.mem_total) * (bar_w - 2));
      if (x + w > bar_x + bar_w - 1) w = bar_x + bar_w - 1 - x;
      if (w > 0) p.rect(x, bar_y + 1, w, bar_h - 2, colors[i]);
      x += w;
    }
  }
  p.text("アプリ", 10, 182, &fonts::lgfxJapanGothicP_16, kMemColor);
  p.text("固定", 80, 182, &fonts::lgfxJapanGothicP_16, 0xFFE0);
  p.text("圧縮", 140, 182, &fonts::lgfxJapanGothicP_16, 0xF81F);
  static const char* const kPressure[3] = {"圧迫度: 通常", "圧迫度: 警告", "圧迫度: 危機"};
  const uint16_t kPressureColor[3] = {kMemColor, 0xFFE0, TFT_RED};
  const int level = r.pressure > 2 ? 2 : r.pressure;
  p.text(kPressure[level], 10, 208, &fonts::lgfxJapanGothicP_16, kPressureColor[level]);
  format_gb(b, sizeof(b), r.swap_used);
  snprintf(a, sizeof(a), "swap %s GB", b);
  p.text(a, 310, 210, &fonts::Font2, kFg, top_right);
}

void draw_network(Pen& p, const Model& m) {
  const pp::Readings& r = m.latest;
  char a[32], b[48];
  snprintf(b, sizeof(b), "%s", r.interface[0] ? r.interface : "-");
  p.text(b, 10, 26, &fonts::Font2, kDim);
  format_rate(a, sizeof(a), r.rx);
  snprintf(b, sizeof(b), "v %s", a);
  p.text(b, 310, 24, &fonts::Font2, kRxColor, top_right);
  format_rate(a, sizeof(a), r.tx);
  snprintf(b, sizeof(b), "^ %s", a);
  p.text(b, 310, 42, &fonts::Font2, kTxColor, top_right);
  const int32_t scale = network_scale(m, 300);
  graph32(p, m.rx, kHistory, 10, 64, 300, 160, scale, kRxColor);
  graph32(p, m.tx, kHistory, 10, 64, 300, 160, scale, kTxColor);
  format_rate(a, sizeof(a), static_cast<uint64_t>(scale));
  p.text(a, 14, 66, &fonts::Font0, kDim);
}

void draw_overlay(Pen& p, const Model& m, WifiState wifi, uint32_t now_ms) {
  const char* message = nullptr;
  if (wifi == WifiState::kFailed) message = "Wi-Fi に接続できません";
  else if (wifi == WifiState::kConnecting) message = "Wi-Fi に接続しています";
  else if (!m.fresh(now_ms)) message = "データ待ち";
  if (message == nullptr) return;
  p.rect(40, 104, 240, 36, 0x0000);
  p.frame(40, 104, 240, 36, kFg);
  p.text(message, 160, 114, &fonts::lgfxJapanGothicP_16, kFg, top_center);
}

void push_bands(void (*paint)(Pen&, void*), void* context) {
  if (!band_ok) return;
  for (int y0 = 0; y0 < 240; y0 += kBand) {
    band.fillSprite(kBg);
    Pen p{y0};
    paint(p, context);
    band.pushSprite(0, y0);
  }
}

}  // namespace

Model::Model() {
  for (int i = 0; i < kHistory; ++i) {
    cpu[i] = gpu[i] = mem[i] = kGap;
    rx[i] = tx[i] = -1;
  }
}

void Model::tick_history(uint32_t now_ms) {
  memmove(cpu, cpu + 1, sizeof(int16_t) * (kHistory - 1));
  memmove(gpu, gpu + 1, sizeof(int16_t) * (kHistory - 1));
  memmove(mem, mem + 1, sizeof(int16_t) * (kHistory - 1));
  memmove(rx, rx + 1, sizeof(int32_t) * (kHistory - 1));
  memmove(tx, tx + 1, sizeof(int32_t) * (kHistory - 1));
  const int last = kHistory - 1;
  if (!fresh(now_ms)) {
    cpu[last] = gpu[last] = mem[last] = kGap;
    rx[last] = tx[last] = -1;
    return;
  }
  cpu[last] = static_cast<int16_t>(latest.cpu_tenths);
  gpu[last] = latest.gpu_present ? static_cast<int16_t>(latest.gpu_tenths) : kGap;
  mem[last] = latest.mem_total == 0
                  ? kGap
                  : static_cast<int16_t>(static_cast<double>(latest.mem_used) / latest.mem_total * 1000.0);
  rx[last] = latest.rx > 0x7FFFFFFF ? 0x7FFFFFFF : static_cast<int32_t>(latest.rx);
  tx[last] = latest.tx > 0x7FFFFFFF ? 0x7FFFFFFF : static_cast<int32_t>(latest.tx);
}

void begin() {
  M5.Display.setRotation(1);
  M5.Display.fillScreen(kBg);
  band.setColorDepth(16);
  band_ok = band.createSprite(kWidth, kBand) != nullptr;
  set_backlight(true);
}

void set_backlight(bool on) { M5.Display.setBrightness(on ? 128 : 0); }

void show_boot_hold(int seconds_left) {
  struct Ctx { int s; } ctx{seconds_left};
  push_bands([](Pen& p, void* c) {
    const int s = static_cast<Ctx*>(c)->s;
    p.text("B を押し続けると", 160, 80, &fonts::lgfxJapanGothicP_16, kFg, top_center);
    p.text("設定を消去します", 160, 102, &fonts::lgfxJapanGothicP_16, kFg, top_center);
    char n[8];
    snprintf(n, sizeof(n), "%d", s);
    p.text(n, 160, 140, &fonts::Font7, TFT_ORANGE, top_center);
  }, &ctx);
}

void show_message(const char* title, const char* body) {
  struct Ctx { const char* t; const char* b; } ctx{title, body};
  push_bands([](Pen& p, void* c) {
    Ctx* x = static_cast<Ctx*>(c);
    p.text(x->t, 160, 70, &fonts::lgfxJapanGothicP_20, kFg, top_center);
    band.setTextWrap(true);
    p.text(x->b, 160, 110, &fonts::lgfxJapanGothicP_16, kDim, top_center);
    p.text(PANEL_SERVICE_NAME " " FW_VERSION, 160, 220, &fonts::Font0, kDim, top_center);
  }, &ctx);
}

void show_setup(const char* ssid, const char* password, const char* status) {
  struct Ctx { const char* s; const char* p; const char* st; } ctx{ssid, password, status};
  push_bands([](Pen& p, void* c) {
    Ctx* x = static_cast<Ctx*>(c);
    p.text("設定", 160, 6, &fonts::lgfxJapanGothicP_20, kFg, top_center);
    p.text("Wi-Fi", 16, 40, &fonts::lgfxJapanGothicP_16, kDim);
    p.text(x->s, 16, 60, &fonts::Font4, kFg);
    p.text("パスワード", 16, 94, &fonts::lgfxJapanGothicP_16, kDim);
    p.text(x->p, 16, 114, &fonts::Font4, TFT_ORANGE);
    p.text("Mac でこの Wi-Fi につなぎ、", 16, 152, &fonts::lgfxJapanGothicP_16, kFg);
    p.text("コンパニオンの「設定を始める」を選ぶ", 16, 172, &fonts::lgfxJapanGothicP_16, kFg);
    p.text(x->st, 16, 204, &fonts::lgfxJapanGothicP_16, TFT_GREEN);
  }, &ctx);
}

void draw(int page, const Model& model, WifiState wifi, uint32_t now_ms) {
  struct Ctx { int page; const Model* m; WifiState w; uint32_t now; } ctx{page, &model, wifi, now_ms};
  push_bands([](Pen& p, void* c) {
    Ctx* x = static_cast<Ctx*>(c);
    draw_header(p, x->page, *x->m, x->w);
    if (x->m->have_readings) {
      switch (x->page) {
        case 0: draw_overview(p, *x->m); break;
        case 1: draw_cpu(p, *x->m); break;
        case 2: draw_gpu_memory(p, *x->m); break;
        default: draw_network(p, *x->m); break;
      }
    }
    draw_overlay(p, *x->m, x->w, x->now);
  }, &ctx);
}

}  // namespace ui
