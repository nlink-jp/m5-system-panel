// m5-system-panel wire protocol v1, panel side (docs/ja/protocol.ja.md).
//
// No Arduino or M5 headers and no heap: fixed buffers only, so the code behaves
// the same in the product sketch and in the on-device test sketch
// (firmware/protocol-test), which checks it against testdata/protocol-v1.json.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace pp {

constexpr size_t kMaxLine = 1024;           // §3, excluding LF
constexpr size_t kMaxPlaintext = 700;       // §4.3
constexpr size_t kKeyBytes = 32;
constexpr size_t kNonceBytes = 16;
constexpr size_t kTagBytes = 16;
constexpr size_t kMaxCores = 64;
constexpr uint64_t kMaxInteger = 0x7FFFFFFFFFFFFFFFULL;  // 2^63 - 1
constexpr uint64_t kCounterLimit = 1ULL << 32;

// --- base64 (RFC 4648 §4, canonical only) ---------------------------------

// Decodes `text` (not NUL-terminated) into `out`. Fails for anything but a
// canonical, non-empty encoding that fits `capacity`.
bool b64_decode(const char* text, size_t length, uint8_t* out, size_t capacity, size_t* out_length);
// Encodes into `out` with a NUL. Returns the length, or 0 when it does not fit.
size_t b64_encode(const uint8_t* data, size_t length, char* out, size_t capacity);

// --- lines (§3) --------------------------------------------------------------

class LineBuffer {
 public:
  enum class Result { kNone, kLine, kError };
  // Feeds one byte. kLine: line() holds a complete line (valid until the next
  // push). kError: over 1024 bytes, CR, or not printable ASCII — close.
  Result push(uint8_t byte);
  const char* line() const { return buffer_; }
  size_t length() const { return length_; }

 private:
  char buffer_[kMaxLine + 1] = {};
  size_t length_ = 0;
  bool complete_ = false;
};

// --- keys (§4.2) -------------------------------------------------------------

// K_cp and K_pc from K (used as the HKDF PRK), the device ID and both nonces.
bool derive_session_keys(const uint8_t key[kKeyBytes], const char device_id[4],
                         const uint8_t np[kNonceBytes], const uint8_t nc[kNonceBytes],
                         uint8_t k_cp[kKeyBytes], uint8_t k_pc[kKeyBytes]);

bool is_device_id(const char* text, size_t length);

// --- frames (§4.3) -------------------------------------------------------------

// One direction of one session: its key and counter. Never rewound.
class FrameCipher {
 public:
  FrameCipher();  // unkeyed: seal/open fail until reset()
  explicit FrameCipher(const uint8_t key[kKeyBytes]);
  ~FrameCipher();
  // A new key and counter 0 — for a new session only, never to rewind one.
  void reset(const uint8_t key[kKeyBytes]);
  void clear();
  // Plaintext (printable ASCII, <= 700 bytes) to an "F ..." line with a NUL.
  bool seal(const char* plaintext, size_t length, char* line, size_t capacity, size_t* line_length);
  // "F ..." line to the plaintext (with a NUL). False: close the connection.
  bool open(const char* line, size_t length, char* plaintext, size_t capacity, size_t* plaintext_length);
  uint64_t counter() const { return counter_; }

 private:
  uint8_t key_[kKeyBytes] = {};
  uint64_t counter_ = 0;
  bool keyed_ = false;
};

// --- messages (§4.1, §4.4) ---------------------------------------------------------

// "HELLO 1 <id> <B64(Np)>" with a NUL.
size_t encode_hello(const char device_id[4], const uint8_t np[kNonceBytes], char* out, size_t capacity);
// "AUTH <B64(Nc)>".
bool parse_auth(const char* line, size_t length, uint8_t nc[kNonceBytes]);

struct Readings {
  uint64_t seq;
  uint16_t cpu_tenths;             // 0..1000
  uint8_t cores[kMaxCores];        // 0..100 each
  uint8_t core_count;              // 1..64
  bool gpu_present;
  uint16_t gpu_tenths;             // valid when gpu_present
  uint64_t mem_used, mem_total, mem_app, mem_wired, mem_compressed, swap_used;
  uint8_t pressure;                // 0..2
  char interface[16];              // "" when "-"
  uint64_t rx, tx;
};

// The "M ..." plaintext; exact form only.
bool parse_readings(const char* text, size_t length, Readings* out);
// "A seq=<n|-> up=<n>" with a NUL; has_seq false writes "-".
size_t encode_ack(bool has_seq, uint64_t seq, uint64_t uptime_ms, char* out, size_t capacity);

}  // namespace pp
