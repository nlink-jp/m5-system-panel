# m5-system-panel wire protocol v2

> English translation. The Japanese version (`docs/ja/protocol.ja.md`) is the primary document.
>
> Status: Accepted (v1: 2026-09-26, v2: 2026-10-05 — adds the brightness level; differences from v1 in §10)
> Related: [RFP](m5-system-panel-rfp.md), [ADR-0001](adr/0001-phase0-premises.md), [ADR-0002](adr/0002-crypto-and-setup-binding.md), [ADR-0003](adr/0003-brightness.md)

This specifies the exchange between the companion (Mac) and the panel (M5). There are two sessions: setup (inside
the panel's setup Wi-Fi) and run (on the home Wi-Fi). "MUST" and "MUST NOT" are rules that implementations and tests follow.

## 1. Terms and notation

| Term | Meaning |
|---|---|
| Panel | The firmware on the M5Stack BASIC v2.7 |
| Companion | The Mac menu bar app |
| Device ID | A 16-bit random value created by the panel at each setup, written as 4 upper-case hex ASCII characters (e.g. `3F2A`) |
| Key K | 32 random bytes created by the panel at each setup |
| B64 | Base64 of RFC 4648 §4 (standard alphabet, `=` padding). **Receivers accept only the canonical form**: correct padding count, zero pad bits, and no characters outside the alphabet (whitespace and newlines included). Anything else is a malformed line |
| `‖` | Byte concatenation |
| `uint64_be(x)` | x as an 8-byte unsigned integer, most significant byte first |

- All random values come from `esp_random()` after the radio is up on the panel (ADR-0001 decision 5) and from
  `SecRandomCopyBytes` on the companion.

## 2. Discovery (run session only; mDNS / DNS-SD)

- In the run state the panel advertises service type `_m5-system-panel._tcp` with instance name `m5-system-panel <device ID>`.
- TXT record: `v=2` (the run session's version, the same as `HELLO`'s), `id=<device ID>`. The companion does not use `v` to pick candidates (it learns the version from `HELLO`).
- Port 47110, published in the SRV record. The companion uses the SRV value.
- The companion tries **every** candidate whose `id` equals the stored device ID. A candidate that failed verification
  (§4.1 item 7) is not chosen again for 60 s, so a fake advertisement with the same ID cannot keep it from the real panel.
- Browse results do not decide whether the panel is present (ADR-0001 decision 1).
- Setup does not use mDNS (§5.1).

## 3. Line format (both sessions)

- ASCII lines over TCP, each terminated by LF (0x0A). No CR.
- A line is **at most 1024 bytes** excluding the LF. A receiver of a longer line MUST close the connection.
- A line is a sequence of tokens separated by a single space (0x20). No empty tokens (an empty value is written with the
  symbol defined for that field).
- A receiver of a line that does not match the defined forms MUST close the connection without replying (no reason is given).

## 4. Run session

### 4.1 Flow

```
Companion                                      Panel
    |---------------- TCP connect ---------------->|  panel starts a 5 s clock here
    |<---- HELLO 2 <device ID> <B64(Np)> ----------|  Np: 16 random bytes
    |----- AUTH <B64(Nc)> ------------------------>|  Nc: 16 random bytes
    |----- F <B64(frame c→p, ctr 0)> ------------->|  session established when the panel verifies it
    |<---- F <B64(frame p→c, ctr 0)> --------------|  "Connected" when the companion verifies it
    |----- F … (every second) --------------------->|
    |<---- F … (every second) ----------------------|
```

1. On accepting a connection the panel immediately sends `HELLO 2 <device ID> <B64(Np)>`, with a fresh Np per connection.
2. If the version is neither `1` nor `2` the companion reports "The M5 firmware does not match"; if the device ID differs from the
   stored one it closes. Otherwise it creates Nc, derives the keys (4.2), and sends `AUTH <B64(Nc)>` and the first frame
   (measurements, ctr 0).
   For the rest of the session it sends measurements in the form of `HELLO`'s version (no `bri` to a version 1 panel — §10).
3. On `AUTH` the panel derives the keys and verifies the frame on the next line.
   - If it verifies, that connection becomes the session. **If another session is established, the older one is closed
     at that moment** (replacement, for a Mac reconnecting after sleep).
   - If it does not verify, or no verifying frame arrives **within 5 s of accept**, only this connection is closed.
4. At most **2 unauthenticated connections** (accepted, not yet verified) exist at a time. Accepting a third closes the oldest
   unauthenticated one. **An established session MUST NOT be closed because of unauthenticated connections.**
5. Once the session is established the panel sends an acknowledgement (4.4) at once and then every second. **If no frame
   arrives on the established session for 10 s, the panel closes it** (the companion sends every second; this keeps the panel
   from writing acknowledgements to a sleeping Mac until its send queue fills). The companion shows "Connected"
   when it verifies the first acknowledgement (confirming the panel knows the key).
6. Either side MUST close the connection without replying when a frame fails verification, when `ctr` does not match, or
   when a malformed line arrives.
7. The companion treats a peer whose `HELLO` is malformed, or whose first acknowledgement after `AUTH` does not verify, as
   "a candidate that failed verification" (§2).
8. The companion's connection supervision (`.preparing` 10 s, 5 s without acknowledgement, …) follows ADR-0001 decision 1.

### 4.2 Key derivation (RFC 5869 HKDF-SHA256, Expand only)

K is 32 uniform random bytes, so, per RFC 5869 §3.3, Extract is skipped and K is used directly as the PRK.

```
ctx  = device ID (4 ASCII bytes) ‖ Np (16 bytes) ‖ Nc (16 bytes)
K_cp = HKDF-Expand(PRK = K, info = "m5-system-panel/1 c2p" ‖ ctx, L = 32)
K_pc = HKDF-Expand(PRK = K, info = "m5-system-panel/1 p2c" ‖ ctx, L = 32)
```

- Strings are ASCII without a terminating NUL (`"m5-system-panel/1 c2p"` is 21 bytes).
- The `/1` in the labels is the version of the key and frame construction, counted apart from `HELLO`'s version (the version
  of the measurement form). Version 2 keeps it (ADR-0003).
- Each direction has its own key. The companion encrypts with K_cp and decrypts with K_pc; the panel the reverse.
- Each side mixes in a fresh random value of its own every time (Np on the panel, Nc on the companion), so a recorded old
  session replayed to either side derives different keys and fails verification. Even if an attacker picks the other
  side's random value, the keys are unique per session.

### 4.3 Frames (NIST SP 800-38D AES-256-GCM)

```
line        = "F " B64( C ‖ T )
nonce (12)  = 0x00000000 ‖ uint64_be(ctr)
AAD         = "m5-system-panel/1" (ASCII, 17 bytes)
C, T        = AES-256-GCM-Encrypt(key = that direction's key, nonce, AAD, P)    T is 16 bytes
```

- `ctr` starts at 0 per direction and increases by 1 for each frame sent. The nonce is not carried in the line (the
  receiver counts). TCP preserves order, so the receiver decrypts with the expected `ctr` and closes on failure. Replays,
  reordering, loss and reflection (sending a peer's frame back — the keys differ per direction) all fail here.
- A direction's key is used in one session only; within a key the nonce is unique through `ctr` (the deterministic
  construction of SP 800-38D §8.2.1).
- The last frame that may be sent has `ctr` = 2^32 − 1. The sender then closes instead of sending more, and a receiver whose
  expected `ctr` reaches 2^32 closes (136 years at one frame per second; it does not happen in practice).
- Plaintext P is ASCII, at most 700 bytes; the sender MUST check the length. A line is then at most
  `2 + 4⌈(700+16)/3⌉ = 958` bytes.

### 4.4 Plaintext contents

The plaintext is one line (no LF) of tokens separated by single spaces; the first token is the kind. Fields appear in the
fixed order below; a missing or repeated field is malformed. **Receivers check form only, not relations between values
(such as used ≤ installed).** A malformed frame MUST be closed on even if it verified.

**Measurements (companion → panel)**

```
M seq=<n> cpu=<pct1> cores=<pct0>[,<pct0>…] gpu=<pct1|-> mem=<n>/<n> app=<n> wired=<n> comp=<n> swap=<n> press=<0|1|2> if=<name|-> rx=<n> tx=<n> bri=<1-5>
```

The version 1 form is the same without the final `bri` (§10).

| Field | Form | Meaning |
|---|---|---|
| `seq` | `<n>` | Measurement number, from 0 per session, +1 each time. Receivers do not check continuity (`ctr` keeps order) |
| `cpu` | `<pct1>` | Overall usage % |
| `cores` | `<pct0>`, comma-separated, 1–64 entries | Per-core usage in logical CPU order (no P/E type — RFP amendment A4) |
| `gpu` | `<pct1>` or `-` | GPU usage; `-` when unavailable (the panel hides GPU) |
| `mem` | `<used bytes>/<installed bytes>` | |
| `app` `wired` `comp` | `<n>` bytes | Memory breakdown (app, wired, compressed) |
| `swap` | `<n>` bytes | Swap used |
| `press` | `0` normal, `1` warning, `2` critical | Memory pressure |
| `if` | `[A-Za-z0-9]{1,15}` or `-` | BSD name of the primary interface (e.g. `en0`); `-` when none |
| `rx` `tx` | `<n>` bytes/s | Receive and send rates |
| `bri` | one digit `1`–`5` | Screen brightness level, `1` darkest and `5` brightest. The panel decides the actual brightness of each level (ADR-0003). Version 2 only |

- `<n>`: decimal integer 0 to 2^63 − 1, no leading zeros (`0` allowed), no sign.
- `<pct1>`: `0.0` to `100.0`, 1–3 integer digits (no leading zeros; `0.5` is fine) and exactly one decimal digit (e.g. `7.5`, `100.0`).
- `<pct0>`: integer `0` to `100`, no leading zeros.
- The longest valid plaintext is 530 bytes (64 cores all `100`, every integer 19 digits, `if` 15 characters, `bri=5`); 524 bytes in version 1.

**Acknowledgement (panel → companion)**

```
A seq=<n|-> up=<n>
```

- `seq`: the `seq` of the last measurement the panel received in this session; `-` if none yet.
- `up`: milliseconds since the panel booted.
- Sent every second while the session is established.

## 5. Setup session

### 5.1 Which peer

The home Wi-Fi password and key K travel in plaintext in the setup session. **The companion MUST open a setup session only
when all of the following hold:**

1. The connection is pinned to the Mac's Wi-Fi interface (Network.framework `requiredInterface`).
2. The destination is the Wi-Fi interface's router address (as received from DHCP), port 47110. No mDNS results or
   user-entered addresses are used.
3. The first line is `SETUP 1 <device ID>`.

Reason: only the access point the Mac has joined can be its Wi-Fi router. The setup Wi-Fi's password appears only on the
panel's screen, and under WPA2 an access point that does not know the password cannot complete the connection with the Mac
(inferred from WPA2's mutual authentication; not measured). A `SETUP` sent by someone on the home LAN does not come from the
Wi-Fi router's address, so no session is opened. Checking the Wi-Fi name (SSID) is not used because an unprivileged app
cannot read it (measured in Phase 0; ADR-0002).

- The companion tries 2 and 3 when the Wi-Fi interface's state changes, and shows "Start setup" in its menu when they hold.
  Nothing from `LIST` on is sent until the user chooses it.

### 5.2 Flow

```
Companion                                      Panel (router of the setup Wi-Fi)
    |---- TCP connect (pinned to Wi-Fi, router:47110) ->|
    |<---- SETUP 1 <device ID> --------------------|
    |----- LIST ---------------------------------->|  optional (manual entry)
    |<---- NET <rssi> <auth> <B64(ssid)> …---------|  scanned before the setup Wi-Fi started
    |<---- END ------------------------------------|
    |----- JOIN <B64(ssid)> <B64(password)|-> ---->|
    |<---- KEY <B64(K)> ---------------------------|  K is created here
    |----- STORED -------------------------------->|  the companion saved K as provisional
    |<---- DONE -----------------------------------|  the panel saved to NVS → restarts
```

- At most 20 `NET` lines, strongest first. Zero-length SSIDs (hidden networks) are left out; for a repeated SSID only the
  strongest is listed.
- `rssi` is an integer in dBm (`-?[0-9]{1,3}`, no leading zeros, never `-0`). `auth` is one of `open` `wpa2` `wpa3` `wpa2wpa3` `other`.
- An SSID is any 1–32 bytes (not necessarily UTF-8), carried in B64.
- The password is B64 of 1–63 bytes, or `-` for a network without authentication.
- The panel creates K after `JOIN`, sends `KEY`, and stores nothing until `STORED`. If the connection drops before
  `STORED`, K and the `JOIN` contents are discarded.
- On `STORED` the panel writes the Wi-Fi settings, device ID and K to NVS, sends `DONE` and restarts. If the write fails it
  closes without `DONE` and shows the failure on screen.
- On `KEY` the companion stores K in the Keychain as provisional and sends `STORED`. On `DONE` it replaces the previous
  registration (device ID and key) with the new one. If the connection drops before `DONE`, it discards the provisional K,
  keeps the previous registration and shows "Setup could not be completed" (if the panel had finished saving, the user
  redoes setup).
- Keychain items are not synchronised, so another Mac of the same user cannot fight over the session with the same key.
  They go to the file-based keychain (the SecItem default on macOS without `kSecUseDataProtectionKeychain`): iCloud Keychain
  exists only in the data protection keychain, whose access groups need a provisioning profile this app does not have, and
  file-based items are never synchronised (TN3137).
- One setup session at a time. The panel closes when no line arrives for: 10 minutes while waiting for the user (from
  `SETUP` until `JOIN` — choosing a network and typing its password), 60 s while waiting for the companion (from `KEY`
  until `STORED`).
- The panel sends no run-session lines in a setup session, and accepts no setup lines in a run session.

### 5.3 The setup Wi-Fi password

- 12 characters from `abcdefghjkmnpqrstuvwxyz23456789` (31 characters, look-alikes removed). Each character takes an
  `esp_random()` value, accepted only within the largest multiple of 31 (values beyond are redrawn) — no bias. About
  59.4 bits.
- Created anew each time setup starts.

## 6. Error handling

| Situation | Panel | Companion |
|---|---|---|
| Line over 1024 bytes / malformed | Close | Close |
| `HELLO` version is neither 1 nor 2 | — | Close; "firmware does not match" |
| `HELLO` device ID differs from the stored one | — | Close (another panel) |
| No verifying frame within 5 s of accept | Close this connection only | — |
| A third unauthenticated connection | Close the oldest unauthenticated one | — |
| Frame fails verification / `ctr` mismatch | Close (before establishment the existing session stays) | Close; avoid that candidate for 60 s |
| First acknowledgement fails verification | — | As above; never show "Connected" |
| 5 s without acknowledgement | — | ADR-0001 decision 1 |
| 10 s without a frame on the established session | Close | — (reconnects on the next connection) |
| Setup peer is not the Wi-Fi router | — | Do not open |

## 7. Test vectors (known answers)

Before implementation, the test data both sides use is created as `testdata/protocol.json`.

- External known answers: RFC 5869 Test Cases 1–3 (HKDF-SHA256; they include Extract, used here to check the primitive) and
  AES-256-GCM known answers (from NIST CAVP gcmEncryptExtIV256, with 96-bit nonces and AAD).
- Known answers of this protocol: K_cp and K_pc from a fixed K, device ID, Np and Nc; frame lines for `ctr` = 0 and 1;
  measurement and acknowledgement plaintexts; the longest valid plaintext (524 bytes in version 1, 530 in version 2); version 2's `HELLO` and measurement frames from the
  same inputs. Generated and fixed by the companion's
  tests; the panel checks the same values in an on-device test sketch.
- Examples to reject: malformed lines, non-canonical B64, frames that fail verification, a skipped `ctr`, a 1025-byte line,
  65 cores, out-of-range values (`cpu=100.1`, …). Both sides must close.
- Version 2 measurements to reject: each version 1 reject with ` bri=3` appended (still refused for its original reason) and
  the `bri` cases (missing, `0`, `6`, `03`, empty, `-`, twice, before `tx`). A version 1 reader refuses a line with `bri`.

## 8. Residual risks (accepted)

- **Disruption cannot be prevented.** A malicious party on the LAN can stop the display by holding unauthenticated
  connections, forging TCP resets or spoofing ARP. **It cannot make the panel show someone else's values, and panels and
  Macs do not cross-talk** (unverified values are never shown, and an established session is replaced only by a verified frame).
- **The setup exchange is protected only by the setup Wi-Fi's encryption.** If someone records the join and brute-forces the
  password (~59.4 bits) offline, K and the home Wi-Fi password can be read from the recorded setup exchange (no forward
  secrecy). A WPA2 password check costs 4096 iterations of PBKDF2-HMAC-SHA1; even at an assumed one million guesses per
  second this averages over ten thousand years (inferred; the guessing rate was not measured).
- The setup Wi-Fi password remains in the joining Mac's System keychain (ADR-0001 measurement 2). It is one-time and
  meaningless after setup, but it is a leftover; the removal guidance follows ADR-0001 decision 4.
- The key and Wi-Fi password in the panel's NVS are plaintext (RFP §7).

## 9. Outside this specification

- How the panel draws, its pages and buttons.
- How the companion measures.
- Several panels or several Macs (out of scope in the RFP).
- The actual brightness of each `bri` level, and the dimming when no data arrives (part of how the panel draws; ADR-0001, ADR-0003).

## 10. Versions

| Version | Shipped in | Difference |
|---|---|---|
| 1 | firmware v0.1.0–v0.1.1 | The first version |
| 2 | firmware from v0.2.0 | `HELLO` version `2`, TXT `v=2`, `bri=<1-5>` at the end of the measurements |

- A version changes **only the form of the run session's measurements**. Key derivation, frames, acknowledgements and error
  handling are the same, and so is the `/1` in the labels (§4.2, §4.3). The setup session (§5, `SETUP 1`) does not change.
- The panel accepts only its own version's form (a version 2 panel closes on measurements without `bri` as malformed).
- The companion connects to both version 1 and version 2 and sends the form of `HELLO`'s version. A version 1 panel cannot
  receive the brightness.
- A version 1 companion that reaches a panel knowing only version 2 receives `HELLO 2` and reports "firmware does not match".
- Rewriting the version (`HELLO` is not protected by the cipher) in either direction leads to malformed measurements or missing
  acknowledgements, and the connection ends — disruption, the same as accepted in §8. It never shows someone else's values.
