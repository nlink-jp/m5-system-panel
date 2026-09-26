#include "panel_sessions.h"

#include <stdio.h>
#include <string.h>

#include "mbedtls/platform_util.h"

namespace pp {
namespace {

bool starts_with(const char* line, size_t length, const char* prefix) {
  const size_t n = strlen(prefix);
  return length >= n && memcmp(line, prefix, n) == 0;
}

const char* auth_name(Auth auth) {
  switch (auth) {
    case Auth::kOpen: return "open";
    case Auth::kWpa2: return "wpa2";
    case Auth::kWpa3: return "wpa3";
    case Auth::kWpa2Wpa3: return "wpa2wpa3";
    default: return "other";
  }
}

}  // namespace

// --- run session ------------------------------------------------------------------

SessionManager::SessionManager(const uint8_t key[kKeyBytes], const char device_id[4], RandomFn random)
    : random_(random) {
  memcpy(key_, key, kKeyBytes);
  memcpy(device_id_, device_id, 4);
}

SessionManager::~SessionManager() { mbedtls_platform_zeroize(key_, sizeof(key_)); }

int SessionManager::slot_for_accept(Sink& sink) {
  int unauthenticated = 0, oldest = -1, free_slot = -1;
  for (int i = 0; i < kSlots; ++i) {
    const Slot& s = slots_[i];
    if (s.state == State::kFree) {
      if (free_slot < 0) free_slot = i;
    } else if (s.state != State::kEstablished) {
      ++unauthenticated;
      if (oldest < 0 || static_cast<int32_t>(s.accepted_at - slots_[oldest].accepted_at) < 0) oldest = i;
    }
  }
  // Never the established session: unauthenticated connections cannot push it out (§4.1 item 4).
  if (unauthenticated >= kMaxUnauthenticated && oldest >= 0) {
    drop(oldest, sink);
    return oldest;
  }
  return free_slot;
}

void SessionManager::on_accept(int slot, uint32_t now_ms, Sink& sink) {
  if (slot < 0 || slot >= kSlots) return;
  Slot& s = slots_[slot];
  s = Slot();
  s.state = State::kAwaitAuth;
  s.accepted_at = now_ms;
  random_(s.np, kNonceBytes);
  char line[64];
  if (encode_hello(device_id_, s.np, line, sizeof(line)) == 0) {
    drop(slot, sink);
    return;
  }
  sink.send(slot, line);
}

bool SessionManager::on_line(int slot, const char* line, size_t length, uint32_t now_ms, Sink& sink,
                             Readings* readings) {
  if (slot < 0 || slot >= kSlots) return false;
  Slot& s = slots_[slot];
  switch (s.state) {
    case State::kFree:
      return false;
    case State::kAwaitAuth: {
      uint8_t nc[kNonceBytes];
      uint8_t k_cp[kKeyBytes], k_pc[kKeyBytes];
      if (!parse_auth(line, length, nc) || !derive_session_keys(key_, device_id_, s.np, nc, k_cp, k_pc)) {
        drop(slot, sink);
        return false;
      }
      s.inbound.reset(k_cp);
      s.outbound.reset(k_pc);
      mbedtls_platform_zeroize(k_cp, sizeof(k_cp));
      mbedtls_platform_zeroize(k_pc, sizeof(k_pc));
      s.state = State::kAwaitFrame;
      return false;
    }
    case State::kAwaitFrame:
    case State::kEstablished: {
      char plain[kMaxPlaintext + 1];
      size_t n = 0;
      Readings r;
      if (!s.inbound.open(line, length, plain, sizeof(plain), &n) || !parse_readings(plain, n, &r)) {
        drop(slot, sink);  // before establishment the existing session is untouched
        return false;
      }
      if (s.state == State::kAwaitFrame) {
        // Verified: this connection becomes the session, replacing any other (§4.1 item 3).
        if (established_slot_ >= 0 && established_slot_ != slot) drop(established_slot_, sink);
        s.state = State::kEstablished;
        established_slot_ = slot;
      }
      s.has_seq = true;
      s.last_seq = r.seq;
      if (readings != nullptr) *readings = r;
      // The first acknowledgement goes out at once, so the companion can confirm the key.
      if (s.last_ack_at == 0 && !send_ack(slot, now_ms, sink)) return false;
      return true;
    }
  }
  return false;
}

void SessionManager::on_closed(int slot) {
  if (slot < 0 || slot >= kSlots) return;
  if (established_slot_ == slot) established_slot_ = -1;
  slots_[slot].inbound.clear();
  slots_[slot].outbound.clear();
  slots_[slot].state = State::kFree;
}

void SessionManager::tick(uint32_t now_ms, Sink& sink) {
  for (int i = 0; i < kSlots; ++i) {
    Slot& s = slots_[i];
    if ((s.state == State::kAwaitAuth || s.state == State::kAwaitFrame) &&
        now_ms - s.accepted_at >= kAuthLimitMs) {
      drop(i, sink);
    } else if (s.state == State::kEstablished && now_ms - s.last_ack_at >= kAckIntervalMs) {
      send_ack(i, now_ms, sink);
    }
  }
}

bool SessionManager::send_ack(int slot, uint32_t now_ms, Sink& sink) {
  Slot& s = slots_[slot];
  char plain[64], line[128];
  size_t n = 0;
  if (encode_ack(s.has_seq, s.last_seq, now_ms, plain, sizeof(plain)) == 0 ||
      !s.outbound.seal(plain, strlen(plain), line, sizeof(line), &n)) {
    drop(slot, sink);  // counter exhausted or encoding impossible: end the session
    return false;
  }
  s.last_ack_at = now_ms == 0 ? 1 : now_ms;
  sink.send(slot, line);
  return true;
}

void SessionManager::drop(int slot, Sink& sink) {
  on_closed(slot);
  sink.close(slot);
}

// --- setup session --------------------------------------------------------------------

size_t prepare_scan(const ScanEntry* entries, size_t count, ScanEntry* out, size_t capacity) {
  size_t n = 0;
  for (size_t i = 0; i < count; ++i) {
    const ScanEntry& e = entries[i];
    if (e.ssid_length == 0 || e.ssid_length > 32) continue;
    size_t j = 0;
    for (; j < n; ++j) {
      if (out[j].ssid_length == e.ssid_length && memcmp(out[j].ssid, e.ssid, e.ssid_length) == 0) break;
    }
    if (j < n) {
      if (e.rssi > out[j].rssi) out[j] = e;
      continue;
    }
    if (n < capacity) {
      out[n++] = e;
    } else {
      // Full: replace the weakest if this one is stronger.
      size_t weakest = 0;
      for (size_t k = 1; k < n; ++k) {
        if (out[k].rssi < out[weakest].rssi) weakest = k;
      }
      if (e.rssi > out[weakest].rssi) out[weakest] = e;
    }
  }
  // Strongest first (insertion sort; n <= 20).
  for (size_t i = 1; i < n; ++i) {
    ScanEntry key = out[i];
    size_t j = i;
    while (j > 0 && out[j - 1].rssi < key.rssi) {
      out[j] = out[j - 1];
      --j;
    }
    out[j] = key;
  }
  return n;
}

size_t encode_net(const ScanEntry& entry, char* out, size_t capacity) {
  if (entry.ssid_length == 0 || entry.ssid_length > 32 || entry.rssi < -999 || entry.rssi > 999) return 0;
  const int written = snprintf(out, capacity, "NET %d %s ", entry.rssi, auth_name(entry.auth));
  if (written <= 0 || static_cast<size_t>(written) >= capacity) return 0;
  const size_t n = b64_encode(entry.ssid, entry.ssid_length, out + written, capacity - written);
  return n == 0 ? 0 : written + n;
}

bool parse_join(const char* line, size_t length, JoinRequest* out) {
  // "JOIN <B64(ssid)> <B64(password)|->"
  if (!starts_with(line, length, "JOIN ")) return false;
  const char* p = line + 5;
  const size_t rest = length - 5;
  const char* space = static_cast<const char*>(memchr(p, ' ', rest));
  if (space == nullptr) return false;
  const size_t ssid_text = space - p;
  const char* pass = space + 1;
  const size_t pass_text = rest - ssid_text - 1;
  if (memchr(pass, ' ', pass_text) != nullptr) return false;
  JoinRequest r = {};
  uint8_t buffer[64];
  size_t n = 0;
  if (!b64_decode(p, ssid_text, buffer, sizeof(buffer), &n) || n < 1 || n > 32) return false;
  memcpy(r.ssid, buffer, n);
  r.ssid_length = static_cast<uint8_t>(n);
  if (pass_text == 1 && pass[0] == '-') {
    r.password_length = 0;
  } else {
    if (!b64_decode(pass, pass_text, buffer, sizeof(buffer), &n) || n < 1 || n > 63) return false;
    memcpy(r.password, buffer, n);
    r.password_length = static_cast<uint8_t>(n);
  }
  *out = r;
  return true;
}

void SetupServer::begin(const char device_id[4], const ScanEntry* networks, size_t count, RandomFn random) {
  memcpy(device_id_, device_id, 4);
  networks_ = networks;
  network_count_ = count;
  random_ = random;
  state_ = State::kIdle;
}

void SetupServer::on_connect(uint32_t now_ms, Sink& sink, int slot) {
  commit_ = Commit();
  state_ = State::kGreeted;
  last_line_at_ = now_ms;
  char line[32];
  const char id[5] = {device_id_[0], device_id_[1], device_id_[2], device_id_[3], '\0'};
  snprintf(line, sizeof(line), "SETUP 1 %s", id);
  sink.send(slot, line);
}

SetupServer::Result SetupServer::on_line(const char* line, size_t length, uint32_t now_ms, Sink& sink, int slot) {
  last_line_at_ = now_ms;
  const bool is_list = length == 4 && memcmp(line, "LIST", 4) == 0;
  if (state_ == State::kGreeted && is_list) {
    char out[96];
    for (size_t i = 0; i < network_count_; ++i) {
      if (encode_net(networks_[i], out, sizeof(out)) > 0) sink.send(slot, out);
    }
    sink.send(slot, "END");
    return Result::kContinue;
  }
  if (state_ == State::kGreeted && parse_join(line, length, &commit_.network)) {
    memcpy(commit_.device_id, device_id_, 4);
    random_(commit_.key, kKeyBytes);  // the radio is up: a true RNG (ADR-0001 decision 5)
    char out[64];
    memcpy(out, "KEY ", 4);
    if (b64_encode(commit_.key, kKeyBytes, out + 4, sizeof(out) - 4) == 0) {
      on_closed();
      sink.close(slot);
      return Result::kClose;
    }
    state_ = State::kKeySent;
    sink.send(slot, out);
    return Result::kContinue;
  }
  if (state_ == State::kKeySent && length == 6 && memcmp(line, "STORED", 6) == 0) {
    state_ = State::kCommitting;
    return Result::kCommit;
  }
  on_closed();
  sink.close(slot);
  return Result::kClose;
}

void SetupServer::done(Sink& sink, int slot) {
  sink.send(slot, "DONE");
}

bool SetupServer::idle(uint32_t now_ms) const {
  return state_ != State::kIdle && state_ != State::kCommitting && now_ms - last_line_at_ >= kIdleLimitMs;
}

void SetupServer::on_closed() {
  // Before STORED nothing is kept (§5.2).
  if (state_ != State::kCommitting) mbedtls_platform_zeroize(&commit_, sizeof(commit_));
  state_ = State::kIdle;
}

}  // namespace pp
