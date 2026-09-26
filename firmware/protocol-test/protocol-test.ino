// On-device check of the PanelProtocol library against testdata/protocol-v1.json
// (vectors.h is generated from it by `make protocol-test`). Not the product.
//
// Checks the mbedTLS primitives against RFC 5869 and NIST CAVP, then the
// protocol's own vectors (produced independently by the companion side) and
// every reject example. Prints "RESULT pass=N fail=M ... failures: <names>"
// every 2 s on the serial port (115200) and the totals on the screen. No Wi-Fi,
// no secrets.

#include <M5Unified.h>
#include <string.h>

#include "mbedtls/gcm.h"
#include "mbedtls/hkdf.h"
#include "mbedtls/md.h"
#include "panel_protocol.h"
#include "panel_sessions.h"
#include "vectors.h"

// The protocol code keeps its buffers on the stack (about 3 KB deep per line);
// the default 8 KB loop task overflowed in test_sessions. The product sketch
// sets the same size. The margin is reported as stack_free_min.
SET_LOOP_TASK_STACK_SIZE(16 * 1024);

static int passed = 0;
static int failed = 0;
static char failures[1024];  // names of failed checks, repeated in every report

static void check(bool ok, const char* name, int index = -1) {
  if (ok) {
    ++passed;
    return;
  }
  ++failed;
  char entry[48];
  if (index >= 0) {
    snprintf(entry, sizeof(entry), " %s[%d]", name, index);
  } else {
    snprintf(entry, sizeof(entry), " %s", name);
  }
  strncat(failures, entry, sizeof(failures) - strlen(failures) - 1);
}

// A macro, not a template: the Arduino preprocessor's prototype generation mangles templates.
#define COUNT(array) (sizeof(array) / sizeof((array)[0]))

static void test_hkdf() {
  const mbedtls_md_info_t* sha256 = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  for (size_t i = 0; i < COUNT(kHkdf); ++i) {
    const HkdfCase& c = kHkdf[i];
    uint8_t prk[32];
    check(mbedtls_hkdf_extract(sha256, c.salt_len ? c.salt : nullptr, c.salt_len, c.ikm, c.ikm_len, prk) == 0 &&
              c.prk_len == 32 && memcmp(prk, c.prk, 32) == 0,
          "hkdf.extract", c.number);
    uint8_t okm[128];
    check(mbedtls_hkdf_expand(sha256, c.prk, c.prk_len, c.info_len ? c.info : nullptr, c.info_len, okm, c.okm_len) == 0 &&
              memcmp(okm, c.okm, c.okm_len) == 0,
          "hkdf.expand", c.number);
  }
}

static void test_gcm() {
  for (size_t i = 0; i < COUNT(kGcm); ++i) {
    const GcmCase& c = kGcm[i];
    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    bool keyed = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, c.key, 256) == 0;
    uint8_t out[64] = {};
    if (!c.expect_fail) {
      uint8_t tag[16];
      check(keyed && mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, c.pt_len, c.iv, 12, c.aad, c.aad_len, c.pt,
                                               out, 16, tag) == 0 &&
                memcmp(out, c.ct, c.pt_len) == 0 && memcmp(tag, c.tag, 16) == 0,
            "gcm.encrypt", c.count);
    }
    const int decrypted = mbedtls_gcm_auth_decrypt(&gcm, c.ct_len, c.iv, 12, c.aad, c.aad_len, c.tag, 16, c.ct, out);
    check(keyed && ((decrypted == 0) != c.expect_fail), c.expect_fail ? "gcm.decrypt_fail" : "gcm.decrypt", c.count);
    mbedtls_gcm_free(&gcm);
  }
}

static void test_protocol() {
  uint8_t kcp[32], kpc[32];
  check(pp::derive_session_keys(kProtoK, kProtoDeviceId, kProtoNp, kProtoNc, kcp, kpc) &&
            memcmp(kcp, kProtoKcp, 32) == 0 && memcmp(kpc, kProtoKpc, 32) == 0,
        "keys");

  char line[pp::kMaxLine + 1];
  check(pp::encode_hello(kProtoDeviceId, kProtoNp, line, sizeof(line)) > 0 && strcmp(line, kProtoHello) == 0, "hello");
  uint8_t nc[16];
  check(pp::parse_auth(kProtoAuth, strlen(kProtoAuth), nc) && memcmp(nc, kProtoNc, 16) == 0, "auth");

  // c2p: the panel opens what the companion sealed, and sealing reproduces it.
  pp::FrameCipher c2p_open(kProtoKcp), c2p_seal(kProtoKcp);
  for (size_t i = 0; i < COUNT(kFrames_c2p); ++i) {
    char plain[pp::kMaxPlaintext + 1];
    size_t n = 0;
    check(c2p_open.open(kFrames_c2p[i].line, strlen(kFrames_c2p[i].line), plain, sizeof(plain), &n) &&
              strcmp(plain, kFrames_c2p[i].plaintext) == 0,
          "c2p.open", i);
    check(c2p_seal.seal(kFrames_c2p[i].plaintext, strlen(kFrames_c2p[i].plaintext), line, sizeof(line), &n) &&
              strcmp(line, kFrames_c2p[i].line) == 0,
          "c2p.seal", i);
    pp::Readings r;
    check(pp::parse_readings(kFrames_c2p[i].plaintext, strlen(kFrames_c2p[i].plaintext), &r), "readings.parse", i);
  }

  // p2c: the panel's acknowledgements, byte for byte.
  pp::FrameCipher p2c(kProtoKpc);
  const bool has_seq[] = {false, true};
  const uint64_t seqs[] = {0, 0};
  const uint64_t ups[] = {4508, 5510};
  for (size_t i = 0; i < COUNT(kFrames_p2c); ++i) {
    char plain[64];
    size_t n = 0;
    check(pp::encode_ack(has_seq[i], seqs[i], ups[i], plain, sizeof(plain)) > 0 &&
              strcmp(plain, kFrames_p2c[i].plaintext) == 0,
          "ack.encode", i);
    check(p2c.seal(plain, strlen(plain), line, sizeof(line), &n) && strcmp(line, kFrames_p2c[i].line) == 0,
          "p2c.seal", i);
  }

  // Frame 0's fields, decoded.
  pp::Readings r;
  const char* first = kFrames_c2p[0].plaintext;
  check(pp::parse_readings(first, strlen(first), &r) && r.seq == 0 && r.cpu_tenths == 234 && r.core_count == 4 &&
            r.cores[0] == 45 && r.cores[3] == 0 && r.gpu_present && r.gpu_tenths == 80 &&
            r.mem_total == 34359738368ULL && strcmp(r.interface, "en0") == 0 && r.rx == 1250000 && r.tx == 48000,
        "readings.fields");
  const char* second = kFrames_c2p[1].plaintext;
  check(pp::parse_readings(second, strlen(second), &r) && !r.gpu_present && r.interface[0] == '\0' && r.pressure == 2,
        "readings.absent");
}

static void test_rejects() {
  uint8_t buffer[64];
  size_t n = 0;
  for (size_t i = 0; i < COUNT(kRejectBase64); ++i) {
    check(!pp::b64_decode(kRejectBase64[i], strlen(kRejectBase64[i]), buffer, sizeof(buffer), &n), "reject.base64", i);
  }
  check(pp::b64_decode("AAE=", 4, buffer, sizeof(buffer), &n) && n == 2 && buffer[1] == 1, "base64.canonical");
  for (size_t i = 0; i < COUNT(kRejectReadings); ++i) {
    pp::Readings r;
    check(!pp::parse_readings(kRejectReadings[i], strlen(kRejectReadings[i]), &r), "reject.readings", i);
  }
  for (size_t i = 0; i < COUNT(kRejectFrames); ++i) {
    pp::FrameCipher opener(kProtoKcp);
    char plain[pp::kMaxPlaintext + 1];
    check(!opener.open(kRejectFrames[i], strlen(kRejectFrames[i]), plain, sizeof(plain), &n), "reject.frame", i);
  }
  pp::LineBuffer too_long;
  pp::LineBuffer::Result last = pp::LineBuffer::Result::kNone;
  for (size_t i = 0; i < kLineTooLong && last != pp::LineBuffer::Result::kError; ++i) last = too_long.push('A');
  check(last == pp::LineBuffer::Result::kError, "reject.line_too_long");
  pp::LineBuffer fits;
  for (size_t i = 0; i < kLineTooLong - 1; ++i) fits.push('A');
  check(fits.push('\n') == pp::LineBuffer::Result::kLine && fits.length() == kLineTooLong - 1, "line.max_fits");
  pp::LineBuffer cr;
  check(cr.push('A') == pp::LineBuffer::Result::kNone && cr.push('\r') == pp::LineBuffer::Result::kError, "reject.cr");
}

static void test_counter() {
  pp::FrameCipher sealer(kProtoKcp);
  char a[128], b[128];
  size_t n = 0;
  sealer.seal("A seq=- up=1", 12, a, sizeof(a), &n);
  sealer.seal("A seq=- up=1", 12, b, sizeof(b), &n);
  check(strcmp(a, b) != 0 && sealer.counter() == 2, "counter.advances");
  pp::FrameCipher opener(kProtoKcp);
  char plain[64];
  check(opener.open(a, strlen(a), plain, sizeof(plain), &n) && !opener.open(a, strlen(a), plain, sizeof(plain), &n),
        "counter.replay_refused");
}


// --- the panel's decisions (panel_sessions) --------------------------------------

// Deterministic "randomness" for the tests: 0, 1, 2, ... (the vectors' K is 0..31).
static uint8_t rng_next = 0;
static void test_random(uint8_t* out, size_t n) {
  for (size_t i = 0; i < n; ++i) out[i] = rng_next++;
}

struct Recorder : pp::Sink {
  char last[pp::SessionManager::kSlots][pp::kMaxLine + 1] = {};
  int sends[pp::SessionManager::kSlots] = {};
  bool closed[pp::SessionManager::kSlots] = {};
  char lines[24][100];
  int line_count = 0;
  void send(int slot, const char* line) override {
    strncpy(last[slot], line, pp::kMaxLine);
    ++sends[slot];
    if (line_count < 24) strncpy(lines[line_count++], line, 99);
  }
  void close(int slot) override { closed[slot] = true; }
};

// The companion's side, built from the same primitives.
struct Companion {
  uint8_t key[32];
  pp::FrameCipher out, in;
  bool start(const char* hello, char* auth_line, char* frame_line, uint64_t seq) {
    const char* last_space = strrchr(hello, ' ');
    uint8_t np[20];
    size_t n = 0;
    if (!last_space || !pp::b64_decode(last_space + 1, strlen(last_space + 1), np, sizeof(np), &n) || n != 16)
      return false;
    uint8_t nc[16];
    memset(nc, 0x77, 16);
    uint8_t kcp[32], kpc[32];
    if (!pp::derive_session_keys(key, "3F2A", np, nc, kcp, kpc)) return false;
    out.reset(kcp);
    in.reset(kpc);
    strcpy(auth_line, "AUTH ");
    pp::b64_encode(nc, 16, auth_line + 5, 40);
    return frame(frame_line, seq);
  }
  bool frame(char* line, uint64_t seq) {
    char plain[160];
    snprintf(plain, sizeof(plain),
             "M seq=%llu cpu=12.5 cores=10,20 gpu=- mem=1/2 app=0 wired=0 comp=0 swap=0 press=0 if=en0 rx=0 tx=0",
             (unsigned long long)seq);
    size_t n = 0;
    return out.seal(plain, strlen(plain), line, pp::kMaxLine + 1, &n);
  }
  bool read_ack(const char* line, char* plain) {
    size_t n = 0;
    return in.open(line, strlen(line), plain, 64, &n);
  }
};

static bool deliver(pp::SessionManager& m, int slot, const char* line, uint32_t now, pp::Sink& sink,
                    pp::Readings* r = nullptr) {
  pp::Readings scratch;
  return m.on_line(slot, line, strlen(line), now, sink, r ? r : &scratch);
}

static void test_sessions() {
  static char auth[64], frame[pp::kMaxLine + 1], plain[64];
  static Recorder rec;
  rec = Recorder();
  pp::SessionManager m(kProtoK, "3F2A", test_random);
  Companion mac;
  memcpy(mac.key, kProtoK, 32);

  // A valid companion becomes the session; the first ack goes out at once.
  int a = m.slot_for_accept(rec);
  m.on_accept(a, 1000, rec);
  check(strncmp(rec.last[a], "HELLO 1 3F2A ", 13) == 0, "session.hello");
  check(mac.start(rec.last[a], auth, frame, 0), "session.companion_start");
  check(!deliver(m, a, auth, 1100, rec), "session.auth_no_readings");
  pp::Readings r;
  const int acks_before = rec.sends[a];
  check(deliver(m, a, frame, 1200, rec, &r) && r.cpu_tenths == 125 && m.established_slot() == a, "session.established");
  check(rec.sends[a] == acks_before + 1 && mac.read_ack(rec.last[a], plain) && strcmp(plain, "A seq=0 up=1200") == 0,
        "session.first_ack");
  m.tick(2200, rec);
  check(mac.read_ack(rec.last[a], plain) && strcmp(plain, "A seq=0 up=2200") == 0, "session.ack_every_second");

  // A connection with another key cannot take over, and does not disturb the session.
  Companion fake;
  memset(fake.key, 9, 32);
  int b = m.slot_for_accept(rec);
  m.on_accept(b, 2300, rec);
  check(fake.start(rec.last[b], auth, frame, 0), "session.fake_start");
  deliver(m, b, auth, 2400, rec);
  check(!deliver(m, b, frame, 2500, rec) && rec.closed[b] && m.established_slot() == a && !rec.closed[a],
        "session.fake_refused");

  // The session keeps working after the intrusion.
  check(mac.frame(frame, 1) && deliver(m, a, frame, 2600, rec, &r) && r.seq == 1, "session.still_established");

  // Unauthenticated connections time out 5 s after accept; the session is untouched.
  int c = m.slot_for_accept(rec);
  rec.closed[c] = false;  // the slot may be the fake's, closed above
  m.on_accept(c, 3000, rec);
  m.tick(7999, rec);
  check(!rec.closed[c], "session.pending_before_limit");
  m.tick(8000, rec);
  check(rec.closed[c] && m.established_slot() == a, "session.pending_timeout");

  // A third unauthenticated connection pushes out the oldest unauthenticated, never the session.
  memset(rec.closed, 0, sizeof(rec.closed));
  int d1 = m.slot_for_accept(rec);
  m.on_accept(d1, 9000, rec);
  int d2 = m.slot_for_accept(rec);
  m.on_accept(d2, 9100, rec);
  int d3 = m.slot_for_accept(rec);
  check(d3 == d1 && rec.closed[d1] && !rec.closed[a] && m.established_slot() == a, "session.unauth_limit");
  m.on_accept(d3, 9200, rec);

  // A second genuine companion (the Mac back from sleep) replaces the session.
  memset(rec.closed, 0, sizeof(rec.closed));
  Companion mac2;
  memcpy(mac2.key, kProtoK, 32);
  check(mac2.start(rec.last[d2], auth, frame, 0), "session.second_start");
  deliver(m, d2, auth, 9300, rec);
  check(deliver(m, d2, frame, 9400, rec) && m.established_slot() == d2 && rec.closed[a], "session.replaced");

  // A bad frame on the session ends it.
  check(!deliver(m, d2, "F AAAA", 9500, rec) && rec.closed[d2] && !m.established(), "session.bad_frame_closes");

  // Malformed AUTH closes.
  memset(rec.closed, 0, sizeof(rec.closed));
  int e = m.slot_for_accept(rec);
  m.on_accept(e, 10000, rec);
  check(!deliver(m, e, "AUTH not-base64", 10100, rec) && rec.closed[e], "session.bad_auth");
}

static void test_setup() {
  static Recorder rec;
  rec = Recorder();
  // Vectors: NET encoding, JOIN parsing, rejects.
  for (size_t i = 0; i < COUNT(kSetupNet); ++i) {
    pp::ScanEntry e = {};
    e.rssi = kSetupNet[i].rssi;
    e.auth = strcmp(kSetupNet[i].auth, "wpa2wpa3") == 0 ? pp::Auth::kWpa2Wpa3 : pp::Auth::kOther;
    memcpy(e.ssid, kSetupNet[i].ssid, kSetupNet[i].ssid_len);
    e.ssid_length = kSetupNet[i].ssid_len;
    char line[96];
    check(pp::encode_net(e, line, sizeof(line)) > 0 && strcmp(line, kSetupNet[i].line) == 0, "setup.net", i);
  }
  for (size_t i = 0; i < COUNT(kSetupJoin); ++i) {
    pp::JoinRequest j;
    check(pp::parse_join(kSetupJoin[i].line, strlen(kSetupJoin[i].line), &j) &&
              j.ssid_length == kSetupJoin[i].ssid_len && memcmp(j.ssid, kSetupJoin[i].ssid, j.ssid_length) == 0 &&
              j.password_length == kSetupJoin[i].password_len &&
              memcmp(j.password, kSetupJoin[i].password, j.password_length) == 0,
          "setup.join", i);
  }
  for (size_t i = 0; i < COUNT(kRejectJoin); ++i) {
    pp::JoinRequest j;
    check(!pp::parse_join(kRejectJoin[i], strlen(kRejectJoin[i]), &j), "reject.join", i);
  }

  // prepare_scan: hidden out, one per SSID (strongest), strongest first, at most 20.
  static pp::ScanEntry raw[25], ready[20];
  memset(raw, 0, sizeof(raw));
  for (int i = 0; i < 25; ++i) {
    raw[i].rssi = -90 + i;
    raw[i].ssid_length = 2;
    raw[i].ssid[0] = 'n';
    raw[i].ssid[1] = static_cast<uint8_t>('a' + i);
  }
  raw[3].ssid_length = 0;             // hidden
  raw[5].ssid[1] = 'a';               // duplicate of raw[0], stronger (-85 > -90)
  const size_t n = pp::prepare_scan(raw, 25, ready, 20);
  bool sorted = true;
  for (size_t i = 1; i < n; ++i) sorted = sorted && ready[i - 1].rssi >= ready[i].rssi;
  check(n == 20 && sorted && ready[0].rssi == -66, "setup.prepare_scan");

  // The exchange.
  pp::SetupServer server;
  pp::ScanEntry nets[1] = {};
  nets[0].rssi = kSetupNet[0].rssi;
  nets[0].auth = pp::Auth::kWpa2Wpa3;
  memcpy(nets[0].ssid, kSetupNet[0].ssid, kSetupNet[0].ssid_len);
  nets[0].ssid_length = kSetupNet[0].ssid_len;
  server.begin("3F2A", nets, 1, test_random);
  server.on_connect(0, rec, 0);
  check(strcmp(rec.last[0], kSetupGreeting) == 0, "setup.greeting");
  rec.line_count = 0;
  check(server.on_line("LIST", 4, 10, rec, 0) == pp::SetupServer::Result::kContinue && rec.line_count == 2 &&
            strcmp(rec.lines[0], kSetupNet[0].line) == 0 && strcmp(rec.lines[1], "END") == 0,
        "setup.list");
  rng_next = 0;  // the key becomes 0..31, the vectors' K
  check(server.on_line(kSetupJoin[0].line, strlen(kSetupJoin[0].line), 20, rec, 0) ==
                pp::SetupServer::Result::kContinue &&
            strcmp(rec.last[0], kSetupKeyLine) == 0,
        "setup.key");
  check(server.on_line("STORED", 6, 30, rec, 0) == pp::SetupServer::Result::kCommit &&
            memcmp(server.commit().key, kProtoK, 32) == 0 && memcmp(server.commit().device_id, "3F2A", 4) == 0 &&
            server.commit().network.ssid_length == 4,
        "setup.commit");
  server.done(rec, 0);
  check(strcmp(rec.last[0], "DONE") == 0, "setup.done");

  // Out of order: STORED before a key was sent closes.
  pp::SetupServer early;
  early.begin("3F2A", nets, 1, test_random);
  rec.closed[0] = false;
  early.on_connect(0, rec, 0);
  check(early.on_line("STORED", 6, 5, rec, 0) == pp::SetupServer::Result::kClose && rec.closed[0],
        "setup.stored_too_early");

  // Idle for 60 s.
  pp::SetupServer quiet;
  quiet.begin("3F2A", nets, 1, test_random);
  quiet.on_connect(1000, rec, 0);
  check(!quiet.idle(60999) && quiet.idle(61000), "setup.idle");
}

void setup() {
  M5.begin();
  Serial.begin(115200);
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  const uint32_t start = millis();
  // Progress with the stack margin, so a crash names the test it happened in.
#define RUN(test)                                                                                   \
  do {                                                                                              \
    Serial.printf("BEGIN %s stack_free=%lu\n", #test, (unsigned long)uxTaskGetStackHighWaterMark(nullptr)); \
    Serial.flush();                                                                                 \
    test();                                                                                         \
  } while (0)
  delay(1500);  // let a serial monitor opened with the reset catch the first lines
  RUN(test_hkdf);
  RUN(test_gcm);
  RUN(test_protocol);
  RUN(test_rejects);
  RUN(test_counter);
  RUN(test_sessions);
  RUN(test_setup);
  const uint32_t elapsed = millis() - start;
  M5.Display.setTextDatum(middle_center);
  M5.Display.setFont(&fonts::Font4);
  M5.Display.setTextColor(failed == 0 ? TFT_GREEN : TFT_RED, TFT_BLACK);
  M5.Display.drawString(failed == 0 ? "PROTOCOL OK" : "PROTOCOL FAIL", 160, 100);
  M5.Display.setFont(&fonts::Font2);
  M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
  char summary[64];
  snprintf(summary, sizeof(summary), "pass %d  fail %d  (%lu ms)", passed, failed, (unsigned long)elapsed);
  M5.Display.drawString(summary, 160, 140);
}

void loop() {
  static uint32_t last = 0;
  if (millis() - last >= 2000) {
    last = millis();
    Serial.printf("RESULT pass=%d fail=%d heap=%lu stack_free_min=%lu failures:%s\n", passed, failed,
                  (unsigned long)ESP.getFreeHeap(), (unsigned long)uxTaskGetStackHighWaterMark(nullptr),
                  failed ? failures : " none");
  }
  M5.update();
  delay(20);
}
