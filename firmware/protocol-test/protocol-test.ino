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
#include "vectors.h"

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

void setup() {
  M5.begin();
  Serial.begin(115200);
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  const uint32_t start = millis();
  test_hkdf();
  test_gcm();
  test_protocol();
  test_rejects();
  test_counter();
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
    Serial.printf("RESULT pass=%d fail=%d heap=%lu failures:%s\n", passed, failed,
                  (unsigned long)ESP.getFreeHeap(), failed ? failures : " none");
  }
  M5.update();
  delay(20);
}
