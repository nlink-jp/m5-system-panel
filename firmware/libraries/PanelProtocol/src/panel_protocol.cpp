#include "panel_protocol.h"

#include <string.h>

#include "mbedtls/base64.h"
#include "mbedtls/gcm.h"
#include "mbedtls/hkdf.h"
#include "mbedtls/md.h"
#include "mbedtls/platform_util.h"

namespace pp {
namespace {

const char kAad[] = "m5-system-panel/1";  // 17 bytes, no NUL on the wire
constexpr size_t kAadBytes = sizeof(kAad) - 1;

bool is_printable(const char* text, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    const uint8_t c = static_cast<uint8_t>(text[i]);
    if (c < 0x20 || c > 0x7E) return false;
  }
  return true;
}

void make_nonce(uint64_t counter, uint8_t nonce[12]) {
  memset(nonce, 0, 4);
  for (int i = 0; i < 8; ++i) nonce[4 + i] = static_cast<uint8_t>(counter >> (56 - 8 * i));
}

// A view of `length` bytes; the protocol text is never NUL-terminated on its own.
struct Span {
  const char* p;
  size_t n;
  bool equals(const char* s) const { return strlen(s) == n && memcmp(p, s, n) == 0; }
};

// Splits at single spaces; empty tokens are kept (and rejected by callers).
size_t split(Span text, char separator, Span* out, size_t max) {
  size_t count = 0, start = 0;
  for (size_t i = 0; i <= text.n; ++i) {
    if (i == text.n || text.p[i] == separator) {
      if (count == max) return max + 1;  // too many
      out[count++] = Span{text.p + start, i - start};
      start = i + 1;
    }
  }
  return count;
}

// <n>: decimal, no sign, no leading zeros, at most 2^63 - 1.
bool parse_uint(Span s, uint64_t* out) {
  if (s.n == 0 || s.n > 19) return false;
  if (s.n > 1 && s.p[0] == '0') return false;
  uint64_t value = 0;
  for (size_t i = 0; i < s.n; ++i) {
    if (s.p[i] < '0' || s.p[i] > '9') return false;
    value = value * 10 + static_cast<uint64_t>(s.p[i] - '0');
  }
  if (value > kMaxInteger) return false;
  *out = value;
  return true;
}

// <pct1> as tenths: 1-3 integer digits without leading zeros, one decimal digit, <= 100.0.
bool parse_tenths(Span s, uint16_t* out) {
  Span parts[2];
  if (split(s, '.', parts, 2) != 2) return false;
  if (parts[0].n < 1 || parts[0].n > 3 || parts[1].n != 1) return false;
  uint64_t whole, tenth;
  if (!parse_uint(parts[0], &whole) || !parse_uint(parts[1], &tenth)) return false;
  const uint64_t value = whole * 10 + tenth;
  if (value > 1000) return false;
  *out = static_cast<uint16_t>(value);
  return true;
}

bool is_interface_name(Span s) {
  if (s.n < 1 || s.n > 15) return false;
  for (size_t i = 0; i < s.n; ++i) {
    const char c = s.p[i];
    if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
  }
  return true;
}

// "name=value" with the value non-empty.
bool field(Span token, const char* name, Span* value) {
  const size_t n = strlen(name);
  if (token.n <= n + 1 || memcmp(token.p, name, n) != 0 || token.p[n] != '=') return false;
  *value = Span{token.p + n + 1, token.n - n - 1};
  return true;
}

size_t put(char* out, size_t capacity, size_t at, const char* text) {
  const size_t n = strlen(text);
  if (at + n >= capacity) return 0;
  memcpy(out + at, text, n + 1);
  return at + n;
}

size_t put_uint(char* out, size_t capacity, size_t at, uint64_t value) {
  char digits[21];
  size_t n = 0;
  do {
    digits[n++] = static_cast<char>('0' + value % 10);
    value /= 10;
  } while (value != 0);
  if (at + n >= capacity) return 0;
  for (size_t i = 0; i < n; ++i) out[at + i] = digits[n - 1 - i];
  out[at + n] = '\0';
  return at + n;
}

}  // namespace

// --- base64 ------------------------------------------------------------------

bool b64_decode(const char* text, size_t length, uint8_t* out, size_t capacity, size_t* out_length) {
  if (length == 0 || length % 4 != 0 || length > kMaxLine) return false;
  size_t n = 0;
  if (mbedtls_base64_decode(out, capacity, &n, reinterpret_cast<const unsigned char*>(text), length) != 0 ||
      n == 0) {
    return false;
  }
  // Canonical only: re-encoding must give back exactly the input (pad bits zero,
  // correct padding, no whitespace — mbedTLS itself tolerates some of these).
  // Compared 3 bytes (4 characters) at a time, to keep this off the stack's budget.
  if ((n + 2) / 3 * 4 != length) return false;
  for (size_t i = 0; i < n; i += 3) {
    unsigned char group[5];
    size_t m = 0;
    const size_t take = n - i < 3 ? n - i : 3;
    if (mbedtls_base64_encode(group, sizeof(group), &m, out + i, take) != 0 || m != 4 ||
        memcmp(group, text + i / 3 * 4, 4) != 0) {
      return false;
    }
  }
  *out_length = n;
  return true;
}

size_t b64_encode(const uint8_t* data, size_t length, char* out, size_t capacity) {
  size_t n = 0;
  if (mbedtls_base64_encode(reinterpret_cast<unsigned char*>(out), capacity, &n, data, length) != 0) return 0;
  return n;  // mbedTLS writes the NUL
}

// --- lines -------------------------------------------------------------------

LineBuffer::Result LineBuffer::push(uint8_t byte) {
  if (complete_) {
    length_ = 0;
    complete_ = false;
  }
  if (byte == 0x0A) {
    buffer_[length_] = '\0';
    complete_ = true;
    return Result::kLine;
  }
  if (byte < 0x20 || byte > 0x7E || length_ >= kMaxLine) return Result::kError;
  buffer_[length_++] = static_cast<char>(byte);
  return Result::kNone;
}

// --- keys ----------------------------------------------------------------------

bool is_device_id(const char* text, size_t length) {
  if (length != 4) return false;
  for (size_t i = 0; i < 4; ++i) {
    const char c = text[i];
    if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
  }
  return true;
}

bool derive_session_keys(const uint8_t key[kKeyBytes], const char device_id[4], const uint8_t np[kNonceBytes],
                         const uint8_t nc[kNonceBytes], uint8_t k_cp[kKeyBytes], uint8_t k_pc[kKeyBytes]) {
  if (!is_device_id(device_id, 4)) return false;
  const mbedtls_md_info_t* sha256 = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (sha256 == nullptr) return false;
  static const char kLabelC2P[] = "m5-system-panel/1 c2p";
  static const char kLabelP2C[] = "m5-system-panel/1 p2c";
  constexpr size_t kLabel = sizeof(kLabelC2P) - 1;  // 21
  uint8_t info[kLabel + 4 + kNonceBytes * 2];
  memcpy(info + kLabel, device_id, 4);
  memcpy(info + kLabel + 4, np, kNonceBytes);
  memcpy(info + kLabel + 4 + kNonceBytes, nc, kNonceBytes);
  memcpy(info, kLabelC2P, kLabel);
  if (mbedtls_hkdf_expand(sha256, key, kKeyBytes, info, sizeof(info), k_cp, kKeyBytes) != 0) return false;
  memcpy(info, kLabelP2C, kLabel);
  return mbedtls_hkdf_expand(sha256, key, kKeyBytes, info, sizeof(info), k_pc, kKeyBytes) == 0;
}

// --- frames ----------------------------------------------------------------------

FrameCipher::FrameCipher() = default;

FrameCipher::FrameCipher(const uint8_t key[kKeyBytes]) { reset(key); }

FrameCipher::~FrameCipher() { clear(); }

void FrameCipher::reset(const uint8_t key[kKeyBytes]) {
  memcpy(key_, key, kKeyBytes);
  counter_ = 0;
  keyed_ = true;
}

void FrameCipher::clear() {
  mbedtls_platform_zeroize(key_, sizeof(key_));
  counter_ = 0;
  keyed_ = false;
}

bool FrameCipher::seal(const char* plaintext, size_t length, char* line, size_t capacity, size_t* line_length) {
  if (!keyed_ || length > kMaxPlaintext || !is_printable(plaintext, length) || counter_ >= kCounterLimit) return false;
  uint8_t sealed[kMaxPlaintext + kTagBytes];
  uint8_t nonce[12];
  make_nonce(counter_, nonce);
  mbedtls_gcm_context gcm;
  mbedtls_gcm_init(&gcm);
  bool ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key_, 256) == 0 &&
            mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, length, nonce, sizeof(nonce),
                                      reinterpret_cast<const uint8_t*>(kAad), kAadBytes,
                                      reinterpret_cast<const uint8_t*>(plaintext), sealed, kTagBytes,
                                      sealed + length) == 0;
  mbedtls_gcm_free(&gcm);
  if (!ok || capacity < 3) return false;
  line[0] = 'F';
  line[1] = ' ';
  const size_t n = b64_encode(sealed, length + kTagBytes, line + 2, capacity - 2);
  if (n == 0) return false;
  ++counter_;
  *line_length = n + 2;
  return true;
}

bool FrameCipher::open(const char* line, size_t length, char* plaintext, size_t capacity, size_t* plaintext_length) {
  if (!keyed_ || counter_ >= kCounterLimit || length < 3 || line[0] != 'F' || line[1] != ' ') return false;
  uint8_t sealed[kMaxLine];
  size_t n = 0;
  if (!b64_decode(line + 2, length - 2, sealed, sizeof(sealed), &n) || n < kTagBytes) return false;
  const size_t cipher_length = n - kTagBytes;
  if (cipher_length > kMaxPlaintext || cipher_length + 1 > capacity) return false;
  uint8_t nonce[12];
  make_nonce(counter_, nonce);
  mbedtls_gcm_context gcm;
  mbedtls_gcm_init(&gcm);
  const bool ok = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key_, 256) == 0 &&
                  mbedtls_gcm_auth_decrypt(&gcm, cipher_length, nonce, sizeof(nonce),
                                           reinterpret_cast<const uint8_t*>(kAad), kAadBytes, sealed + cipher_length,
                                           kTagBytes, sealed, reinterpret_cast<uint8_t*>(plaintext)) == 0;
  mbedtls_gcm_free(&gcm);
  if (!ok) return false;
  ++counter_;
  if (!is_printable(plaintext, cipher_length)) return false;
  plaintext[cipher_length] = '\0';
  *plaintext_length = cipher_length;
  return true;
}

// --- messages --------------------------------------------------------------------

size_t encode_hello(const char device_id[4], const uint8_t np[kNonceBytes], char* out, size_t capacity) {
  if (!is_device_id(device_id, 4)) return 0;
  char id[5] = {device_id[0], device_id[1], device_id[2], device_id[3], '\0'};
  size_t at = put(out, capacity, 0, "HELLO 2 ");
  if (at == 0 || (at = put(out, capacity, at, id)) == 0 || (at = put(out, capacity, at, " ")) == 0) return 0;
  const size_t n = b64_encode(np, kNonceBytes, out + at, capacity - at);
  return n == 0 ? 0 : at + n;
}

bool parse_auth(const char* line, size_t length, uint8_t nc[kNonceBytes]) {
  Span tokens[2];
  if (split(Span{line, length}, ' ', tokens, 2) != 2 || !tokens[0].equals("AUTH")) return false;
  uint8_t decoded[kNonceBytes + 3];
  size_t n = 0;
  if (!b64_decode(tokens[1].p, tokens[1].n, decoded, sizeof(decoded), &n) || n != kNonceBytes) return false;
  memcpy(nc, decoded, kNonceBytes);
  return true;
}

bool parse_readings(const char* text, size_t length, Readings* out) {
  static const char* const kNames[] = {"seq",  "cpu",   "cores", "gpu", "mem", "app", "wired",
                                       "comp", "swap",  "press", "if",  "rx",  "tx",  "bri"};
  constexpr size_t kFields = sizeof(kNames) / sizeof(kNames[0]);
  Span tokens[kFields + 1];
  if (split(Span{text, length}, ' ', tokens, kFields + 1) != kFields + 1 || !tokens[0].equals("M")) return false;
  Span v[kFields];
  for (size_t i = 0; i < kFields; ++i) {
    if (!field(tokens[i + 1], kNames[i], &v[i])) return false;
  }
  Readings r = {};
  if (!parse_uint(v[0], &r.seq) || !parse_tenths(v[1], &r.cpu_tenths)) return false;

  Span cores[kMaxCores];
  const size_t core_count = split(v[2], ',', cores, kMaxCores);
  if (core_count < 1 || core_count > kMaxCores) return false;
  for (size_t i = 0; i < core_count; ++i) {
    uint64_t value;
    if (!parse_uint(cores[i], &value) || value > 100) return false;
    r.cores[i] = static_cast<uint8_t>(value);
  }
  r.core_count = static_cast<uint8_t>(core_count);

  if (v[3].equals("-")) {
    r.gpu_present = false;
  } else {
    if (!parse_tenths(v[3], &r.gpu_tenths)) return false;
    r.gpu_present = true;
  }
  Span mem[2];
  if (split(v[4], '/', mem, 2) != 2 || !parse_uint(mem[0], &r.mem_used) || !parse_uint(mem[1], &r.mem_total)) {
    return false;
  }
  uint64_t press;
  if (!parse_uint(v[5], &r.mem_app) || !parse_uint(v[6], &r.mem_wired) || !parse_uint(v[7], &r.mem_compressed) ||
      !parse_uint(v[8], &r.swap_used) || !parse_uint(v[9], &press) || press > 2) {
    return false;
  }
  r.pressure = static_cast<uint8_t>(press);
  if (v[10].equals("-")) {
    r.interface[0] = '\0';
  } else {
    if (!is_interface_name(v[10])) return false;
    memcpy(r.interface, v[10].p, v[10].n);
    r.interface[v[10].n] = '\0';
  }
  if (!parse_uint(v[11], &r.rx) || !parse_uint(v[12], &r.tx)) return false;
  uint64_t bri;
  if (!parse_uint(v[13], &bri) || bri < kMinBrightness || bri > kMaxBrightness) return false;
  r.brightness = static_cast<uint8_t>(bri);
  *out = r;
  return true;
}

size_t encode_ack(bool has_seq, uint64_t seq, uint64_t uptime_ms, char* out, size_t capacity) {
  if ((has_seq && seq > kMaxInteger) || uptime_ms > kMaxInteger) return 0;
  size_t at = put(out, capacity, 0, "A seq=");
  if (at == 0) return 0;
  at = has_seq ? put_uint(out, capacity, at, seq) : put(out, capacity, at, "-");
  if (at == 0 || (at = put(out, capacity, at, " up=")) == 0) return 0;
  return put_uint(out, capacity, at, uptime_ms);
}

}  // namespace pp
