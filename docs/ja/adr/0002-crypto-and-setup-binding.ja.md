# ADR-0002: 暗号の部品を AES-256-GCM にし、設定時の相手を Wi-Fi のルーターに縛る

| Field | Value |
|-------|-------|
| Status | **Accepted** |
| Date | 2026-09-26 |
| Binds | m5-system-panel |
| Decision makers | nlink-jp maintainers |
| Triggered by | 通信仕様 v1 の作成（RFP §4 Phase 1）と、その独立検証 |

## Context

RFP は、通常時のフレームを ChaCha20-Poly1305（RFC 8439）で守り、設定用 Wi-Fi の中で鍵を渡すとした。
通信仕様 v1（[protocol.ja.md](../protocol.ja.md)）を書く前に、パネル側で使う部品が実在するかを確かめた。
また、仕様の下書きを一次資料（NIST SP 800-38D、RFC 5869、RFC 4648）と突き合わせる独立検証を行った。

**部品の確認（arduino-esp32 3.3.8 のビルド済みライブラリ。2026-09-26 に手元で確認）**

| 対象 | 結果 |
|---|---|
| `sdkconfig` | `CONFIG_MBEDTLS_CHACHA20_C`・`CONFIG_MBEDTLS_POLY1305_C` は無効（`is not set`）。`CONFIG_MBEDTLS_GCM_C`・`CONFIG_MBEDTLS_AES_C`・`CONFIG_MBEDTLS_HARDWARE_AES`・`CONFIG_MBEDTLS_HKDF_C` は有効 |
| `libmbedcrypto.a` の定義済みの記号 | `mbedtls_chachapoly_encrypt_and_tag` は無い。`esp_aes_gcm_*`（ハードウェア AES を使う GCM）、`mbedtls_hkdf`・`mbedtls_hkdf_expand`・`mbedtls_hkdf_extract` はある |
| ヘッダ | `port/include/gcm_alt.h` が `mbedtls_gcm_setkey` などを `esp_aes_gcm_*` に置き換える。`chachapoly.h` はあるが、実体は組み込まれていない |
| CryptoKit（macOS SDK の swiftinterface） | `HKDF.expand(pseudoRandomKey:info:outputByteCount:)` がある。`AES.GCM` はある |

**独立検証の重大な指摘**

1. 設定時のセッションを「設定用 Wi-Fi の上だけ」に限る規則が無く、家の LAN で偽の設定中のパネルを名乗られると、
   家の Wi-Fi のパスワードを渡し、鍵を上書きされる。提案は「つながっている Wi-Fi の SSID を確かめる」。
2. 設定時の安全の前提（使い捨てのパスワードの WPA2）の書き方が過大で、残る危険が書かれていない。

ほかに、HKDF の salt に攻撃者が選べる値を入れている（RFC 5869 §3.4）、平文の上限を正当な値が超える、未成立の接続の数に
上限が無い、同じ ID の偽の公開への対処が無い、実装どうしで解釈が割れる書き方がある、キーチェーンの同期、の指摘があった。
同じ鍵と nonce の組が二度使われる経路は無い、という確認も得た。

**SSID は確かめられない。** Phase 0 で、特権の無いプロセスからは今の SSID が読めないことを実測した
（`ipconfig getsummary` は伏せ字、`networksetup -getairportnetwork` は「未接続」と答える。spikes/README.md の 2）。
アプリから SSID を読むには位置情報の許可が要り、OS が管理する許可を 1 つ増やすことになる。

## Decision

1. **フレームは AES-256-GCM（NIST SP 800-38D）で守る。** nonce は `0x00000000 ‖ uint64_be(ctr)` の決定的な作り方（§8.2.1）、
   タグは 16 バイト。パネルは `mbedtls_gcm_*`（ハードウェア AES）、コンパニオンは CryptoKit の `AES.GCM` を使う。
   ChaCha20-Poly1305 はパネルで使えないので採らない。
2. **鍵の導出は HKDF-SHA256 の Expand だけにする**（RFC 5869 §3.3。K は一様な 32 バイト）。`info` に方向・版・機器 ID・
   両側の乱数を入れる。攻撃者が選べる値を salt に入れない。
3. **設定時の相手は、Wi-Fi のインターフェースに固定した接続で、その Wi-Fi のルーターのアドレスに限る。**
   Mac の Wi-Fi のルーターになれるのは Mac が参加したアクセスポイントだけで、WPA2 ではパスワード（パネルの画面にしか
   出ない）を知らないアクセスポイントは接続を確立できない（WPA2 の相互認証からの推論）。SSID の確認は、位置情報の許可を
   足すことになるので採らない。設定時は mDNS を使わない（Phase 0 で未確認だった「設定用 Wi-Fi の側の mDNS」の問題も消える）。
4. **残る危険として、LAN の上での妨害（表示を止めること）を受け入れる**（運営者の判断、2026-09-26）。偽の値の表示と混線は
   起きないことを守る。設定時の通信は設定用 Wi-Fi の暗号だけで守られること（前方秘匿性なし）と、その強さの見積もりを仕様に書く。
5. 検証のそのほかの指摘は、仕様 v1 の本文にすべて反映する（未成立の接続は 2 本まで、時間切れは受け付けから 5 秒、
   同じ ID の候補をすべて試す、平文の値の書式、正規の base64 だけを受け付ける、仮の鍵の扱い、キーチェーンを同期しない）。

## Consequences

- RFP の ChaCha20-Poly1305 / RFC 8439 の記述は、追補 A3 でこの ADR に置き換わる。独立検証の照合先は SP 800-38D になる。
- パネル側の暗号はハードウェアの AES を使う。GHASH はソフトウェアだが、1 秒に 1 回のフレームなら負荷は問題にならないと読む（推論）。
- コンパニオンが Wi-Fi のインターフェースのルーターのアドレスを、特権無しで取得できることは、Phase 1 の実装の最初に確かめる
  （`ipconfig getoption <IF> router` が特権無しで答えることは Phase 0 で実測済み。API での取得は未確認）。
- 「WPA2 ではパスワードを知らないアクセスポイントは接続を確立できない」は推論のまま。設定時の通し試験で、パスワードを
  変えた偽の設定用 Wi-Fi に Mac が参加できないことを確かめられれば記録を足す（必須にはしない）。

## Alternatives considered

| 案 | 採らない理由 |
|---|---|
| ChaCha20-Poly1305 を自前でビルドして載せる | 組み込み済みのライブラリの設定を変えるか、暗号を自前で持ち込むことになる。AES-GCM は両側の一次提供物にある |
| AES-CCM | パネルにはあるが、CryptoKit に無い |
| SSID で設定時の相手を確かめる | 特権無しでは読めない。位置情報の許可を足すことになる |
| 設定時の相手を mDNS の `mode=setup` で選ぶ | 家の LAN の誰でも名乗れる（独立検証の指摘 1） |
| 設定用 Wi-Fi を WPA3-SAE にする | 総当たりへの耐性は上がるが、パネルと macOS の両方で振る舞いを実測し直すことになる。約 59.4 ビットのパスワードの総当たりは現実的でないと見積もった（仕様 §8） |
| HKDF の Extract に両側の乱数を salt として使う | 攻撃者が選べる値を salt に入れることになる（RFC 5869 §3.4） |
