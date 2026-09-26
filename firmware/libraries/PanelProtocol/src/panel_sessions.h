// The panel's decisions for protocol v1, as pure logic: which connection may
// become the session, when to close, what to send (§4.1, §5.2). No sockets, no
// clock, no randomness of their own — the sketch supplies events and the time,
// and a random source, so the rules are checked on the device by
// firmware/protocol-test with a simulated companion.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "panel_protocol.h"

namespace pp {

using RandomFn = void (*)(uint8_t* out, size_t length);

// What the logic asks the sketch to do. Lines carry no LF; the sketch adds it.
class Sink {
 public:
  virtual ~Sink() = default;
  virtual void send(int slot, const char* line) = 0;
  virtual void close(int slot) = 0;
};

// --- run session (§4.1) -----------------------------------------------------------

class SessionManager {
 public:
  static constexpr int kSlots = 3;                 // 2 unauthenticated + 1 established
  static constexpr int kMaxUnauthenticated = 2;
  static constexpr uint32_t kAuthLimitMs = 5000;   // from accept
  static constexpr uint32_t kAckIntervalMs = 1000;

  SessionManager(const uint8_t key[kKeyBytes], const char device_id[4], RandomFn random);
  ~SessionManager();

  // A connection was accepted into `slot` (0..kSlots-1, currently free).
  void on_accept(int slot, uint32_t now_ms, Sink& sink);
  // A complete line arrived on `slot`. Returns true when it carried readings,
  // which are then in `readings`.
  bool on_line(int slot, const char* line, size_t length, uint32_t now_ms, Sink& sink, Readings* readings);
  // The socket in `slot` went away on its own.
  void on_closed(int slot);
  // Timeouts and acknowledgements.
  void tick(uint32_t now_ms, Sink& sink);

  // A free slot for the next accept, closing the oldest unauthenticated
  // connection if the unauthenticated limit is reached. -1 when none can be made.
  int slot_for_accept(Sink& sink);
  bool established() const { return established_slot_ >= 0; }
  int established_slot() const { return established_slot_; }

 private:
  enum class State : uint8_t { kFree, kAwaitAuth, kAwaitFrame, kEstablished };
  struct Slot {
    State state = State::kFree;
    uint32_t accepted_at = 0;
    uint32_t last_ack_at = 0;
    uint8_t np[kNonceBytes] = {};
    FrameCipher inbound;   // c2p
    FrameCipher outbound;  // p2c
    bool has_seq = false;
    uint64_t last_seq = 0;
  };

  void drop(int slot, Sink& sink);
  bool send_ack(int slot, uint32_t now_ms, Sink& sink);

  uint8_t key_[kKeyBytes];
  char device_id_[4];
  RandomFn random_;
  Slot slots_[kSlots];
  int established_slot_ = -1;
};

// --- setup session (§5.2) ------------------------------------------------------------

enum class Auth : uint8_t { kOpen, kWpa2, kWpa3, kWpa2Wpa3, kOther };

struct ScanEntry {
  int16_t rssi;
  Auth auth;
  uint8_t ssid[32];
  uint8_t ssid_length;  // 0 = hidden
};

// Hidden networks out, one entry per SSID (the strongest), strongest first, at
// most 20 (§5.2). Returns the count written to `out`.
size_t prepare_scan(const ScanEntry* entries, size_t count, ScanEntry* out, size_t capacity);

// "NET <rssi> <auth> <B64(ssid)>" with a NUL.
size_t encode_net(const ScanEntry& entry, char* out, size_t capacity);

struct JoinRequest {
  uint8_t ssid[32];
  uint8_t ssid_length;      // 1..32
  uint8_t password[63];
  uint8_t password_length;  // 0 = "-" (no authentication)
};
bool parse_join(const char* line, size_t length, JoinRequest* out);

// What a finished setup saves (the sketch writes it to NVS, then calls done()).
struct Commit {
  JoinRequest network;
  char device_id[4];
  uint8_t key[kKeyBytes];
};

class SetupServer {
 public:
  static constexpr uint32_t kIdleLimitMs = 60000;
  enum class Result { kContinue, kCommit, kClose };

  // `device_id` is the one on the screen; `networks` from prepare_scan.
  void begin(const char device_id[4], const ScanEntry* networks, size_t count, RandomFn random);
  // A new setup connection (only one at a time; the sketch refuses a second).
  void on_connect(uint32_t now_ms, Sink& sink, int slot);
  // kCommit: save `commit()`, then call done(); on a failed save, close.
  Result on_line(const char* line, size_t length, uint32_t now_ms, Sink& sink, int slot);
  // After the save succeeded: sends DONE. The sketch then restarts.
  void done(Sink& sink, int slot);
  // Closes after 60 s without a line.
  bool idle(uint32_t now_ms) const;
  void on_closed();
  const Commit& commit() const { return commit_; }

 private:
  enum class State : uint8_t { kIdle, kGreeted, kKeySent, kCommitting };
  State state_ = State::kIdle;
  char device_id_[4] = {};
  const ScanEntry* networks_ = nullptr;
  size_t network_count_ = 0;
  RandomFn random_ = nullptr;
  uint32_t last_line_at_ = 0;
  Commit commit_ = {};
};

}  // namespace pp
