# ADR-0002: AES-256-GCM for the frames, and the setup peer bound to the Wi-Fi router

> English translation. The Japanese version (`docs/ja/adr/0002-crypto-and-setup-binding.ja.md`) is the primary document.

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-09-26 |
| Binds | m5-system-panel |
| Decision makers | nlink-jp maintainers |
| Triggered by | Writing the wire protocol v1 (RFP §4 Phase 1) and its independent review |

## Context

The RFP protected the run-time frames with ChaCha20-Poly1305 (RFC 8439) and handed the key over inside the setup
Wi-Fi. Before writing the protocol v1 ([protocol.md](../protocol.md)), the primitives the panel would use were checked
for existence, and the draft was independently reviewed against the primary sources (NIST SP 800-38D, RFC 5869, RFC 4648).

**Primitive check (arduino-esp32 3.3.8 prebuilt libraries; checked locally on 2026-09-26)**

| Target | Result |
|---|---|
| `sdkconfig` | `CONFIG_MBEDTLS_CHACHA20_C` and `CONFIG_MBEDTLS_POLY1305_C` are off (`is not set`). `CONFIG_MBEDTLS_GCM_C`, `CONFIG_MBEDTLS_AES_C`, `CONFIG_MBEDTLS_HARDWARE_AES` and `CONFIG_MBEDTLS_HKDF_C` are on |
| Defined symbols in `libmbedcrypto.a` | No `mbedtls_chachapoly_encrypt_and_tag`. `esp_aes_gcm_*` (GCM on the hardware AES), `mbedtls_hkdf`, `mbedtls_hkdf_expand`, `mbedtls_hkdf_extract` are present |
| Headers | `port/include/gcm_alt.h` maps `mbedtls_gcm_setkey` etc. to `esp_aes_gcm_*`. `chachapoly.h` exists but its implementation is not built in |
| CryptoKit (macOS SDK swiftinterface) | `HKDF.expand(pseudoRandomKey:info:outputByteCount:)` and `AES.GCM` are present |

**The review's blocking findings**

1. Nothing restricted the setup session to the setup Wi-Fi; a fake "panel in setup" on the home LAN would receive
   the home Wi-Fi password and overwrite the key. Suggested: check the SSID the Mac is joined to.
2. The setup session's security premise (a one-time WPA2 password) was overstated and its residual risks unstated.

Other findings: attacker-chosen values in the HKDF salt (RFC 5869 §3.4), a plaintext limit that valid values could
exceed, no cap on unauthenticated connections, no handling of fake advertisements with the same ID, wording two
implementations could read differently, and Keychain synchronisation. The review also confirmed there is no path on
which a (key, nonce) pair is used twice.

**The SSID cannot be checked.** Phase 0 measured that an unprivileged process cannot read the current SSID
(`ipconfig getsummary` redacts it, `networksetup -getairportnetwork` reports "not associated"; spikes/README.md item 2).
An app needs the Location permission to read it — one more OS-managed permission.

## Decision

1. **Frames are protected with AES-256-GCM (NIST SP 800-38D)**, deterministic nonce `0x00000000 ‖ uint64_be(ctr)`
   (§8.2.1), 16-byte tag. The panel uses `mbedtls_gcm_*` (hardware AES); the companion uses CryptoKit `AES.GCM`.
   ChaCha20-Poly1305 is not available on the panel and is dropped.
2. **Keys are derived with HKDF-SHA256 Expand only** (RFC 5869 §3.3; K is 32 uniform bytes), with direction, version,
   device ID and both sides' random values in `info`. No attacker-chosen value goes into a salt.
3. **The setup peer is the Wi-Fi interface's router, over a connection pinned to that interface.** Only the access
   point the Mac joined can be its Wi-Fi router, and under WPA2 an access point that does not know the password (shown
   only on the panel's screen) cannot complete the connection (inferred from WPA2's mutual authentication). Checking
   the SSID is not adopted because it would add the Location permission. mDNS is not used for setup (which also retires
   the Phase 0 open question of mDNS on the SoftAP side).
4. **Disruption on the LAN (stopping the display) is accepted as a residual risk** (maintainer's decision, 2026-09-26).
   Showing someone else's values and cross-talk remain impossible. The specification states that the setup exchange is
   protected only by the setup Wi-Fi's encryption (no forward secrecy) and estimates its strength.
5. The review's other findings are all folded into the v1 text (at most two unauthenticated connections, the 5 s timeout
   counted from accept, trying every candidate with the ID, value formats, canonical base64 only, the provisional key,
   no Keychain synchronisation).

## Consequences

- The RFP's ChaCha20-Poly1305 / RFC 8439 wording is superseded by this ADR through amendment A3; the independent check is
  made against SP 800-38D.
- The panel's cipher uses the hardware AES; GHASH runs in software, which should not matter at one frame per second (inferred).
- Whether the companion can obtain the Wi-Fi interface's router address without privileges through an API is checked first
  in the Phase 1 implementation (`ipconfig getoption <IF> router` answered unprivileged in Phase 0; the API is not yet checked).
- "Under WPA2 an access point that does not know the password cannot complete the connection" remains inferred. If the
  end-to-end setup test can show the Mac failing to join a fake setup Wi-Fi with a different password, the record is added
  (not required).

## Alternatives considered

| Option | Why not |
|---|---|
| Build ChaCha20-Poly1305 into the panel ourselves | Changes the prebuilt library configuration or brings in our own crypto; AES-GCM is in both sides' first-party libraries |
| AES-CCM | On the panel, but not in CryptoKit |
| Check the SSID to identify the setup peer | Not readable unprivileged; would add the Location permission |
| Pick the setup peer from mDNS `mode=setup` | Anyone on the home LAN can advertise it (review finding 1) |
| WPA3-SAE for the setup Wi-Fi | Stronger against brute force, but the panel's and macOS's behaviour would need re-measuring; brute-forcing a ~59.4-bit password was estimated impractical (protocol §8) |
| Use both random values as the HKDF Extract salt | Puts attacker-chosen values into the salt (RFC 5869 §3.4) |
