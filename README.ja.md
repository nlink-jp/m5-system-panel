# m5-system-panel

[English](README.md)

机に置いた M5Stack BASIC を、1 台の Mac 専用の小さな計器盤にします。CPU・GPU・
メモリ・ネットワークを常時表示します。Mac のメニューバーに常駐するアプリ
（コンパニオン）が値を計測して Wi-Fi で送り、パネルは描画するだけです。3 つの
ボタンは表示ページの切り替えに使います。

> macOS 版は **Developer ID で署名し、Apple の公証を受けて**います（staple 済み）。
> Gatekeeper の警告なしで起動し、オフラインでも動きます。

## できること

- **パネルに 5 ページ**: 4 項目の概要、CPU（全体とコアごと）、GPU、メモリ（内訳・圧迫度・
  スワップ）、ネットワーク（上りを上に赤で、下りを下に緑で描く）。各項目のページでは約 5 分、
  概要では約 2.5 分の推移を表示します。
- **ボタン**: A で前のページ、C で次のページ、B で概要に戻ります。
- **データは Wi-Fi で送る。** USB ケーブルは給電だけに使います。
- **あなたのパネルを動かせるのはあなたの Mac だけ。** 設定のときにパネルと
  コンパニオンで鍵を共有し、パネルはその鍵で送られていないものを無視します。
  同じネットワークに複数のパネルや Mac があっても混線しません。
- **明るさはメニューから 5 段階で選べる。** 選んだ段階は Mac に保存し、毎秒の値と一緒に
  パネルへ送ります（パネルは保存しません）。パネルが起動してから最初の値が届くまでは段階 3 で点きます。
- **Mac が眠るとパネルも休む。** 値が 3 秒届かないと「データ待ち」、5 分続くと
  画面を消します。値が届くかボタンを押すと戻ります。

## 動作環境

- M5Stack BASIC v2.7
- Apple Silicon の Mac、macOS 26 以降
- 機器どうしが通信できる 2.4 GHz の Wi-Fi（WPA2・WPA3 パーソナル、または認証なし）。
  端末どうしの通信を遮断するゲスト用 Wi-Fi と、企業向けの認証（802.1X）には対応しません。
  一覧に出ないネットワークは名前を入力できますが、見えない SSID への接続は確かめていません。

## インストール

### コンパニオン（Mac）

```bash
brew install --cask nlink-jp/tap/m5-system-panel
```

または、[Releases](https://github.com/nlink-jp/m5-system-panel/releases) から
`m5-system-panel-v<版>-darwin-arm64.zip` を取得し、`M5SystemPanel.app` を
「アプリケーション」フォルダに移します。

初めて起動すると、macOS が**ローカルネットワークへのアクセス**の許可を求めます。
パネルを見つけて値を送るのに必要なので「許可」を選んでください。システム設定 ›
プライバシーとセキュリティ › ローカルネットワーク で、後から切り替えられます
（一覧には「M5SystemPanel」と出ます）。

### ファームウェア（M5Stack BASIC）

[Releases](https://github.com/nlink-jp/m5-system-panel/releases) から
`m5-system-panel-firmware-v<版>-m5stack-basic.zip` を取得して展開し、Espressif の
[esptool](https://docs.espressif.com/projects/esptool/)（5.x）で書き込みます。
esptool 5 は Python 3.10 以上が要るため、macOS 付属の Python（3.9）の `pip` では古い 4.x が入ります。
Homebrew で入れてください。

```bash
brew install esptool
esptool version
```

`esptool version` が 5.x を表示することを確かめます。

M5 を USB でつなぎ、ポート名（`/dev/cu.usbserial-…`）を確かめます。

```bash
ls /dev/cu.usbserial-*
```

**初めて書き込むとき**は、先にフラッシュを消去します（ほかのファームウェアの設定が残らないように）。

```bash
esptool --chip esp32 --port /dev/cu.usbserial-XXXX erase-flash
```

展開したフォルダで書き込みます（速度は 230400 bps。これより速いと途中で止まることがあります）。

```bash
esptool --chip esp32 --port /dev/cu.usbserial-XXXX --baud 230400 write-flash -z --flash-mode keep --flash-freq keep --flash-size keep 0x1000 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 m5-system-panel.bin
```

新しい版への**更新**は、消去をせずに書き込みだけを行います。設定は残ります。

**v0.1.x から v0.2 以降へ更新するとき**は、コンパニオンを先に更新してください。新しいコンパニオンは
古いファームウェアとも動きます（明るさは選べません）が、古いコンパニオンは新しいファームウェアに
「パネルのファームウェアが違います」と表示します（[通信仕様 §10](docs/ja/protocol.ja.md)）。

## 初めての設定

1. 設定のない M5 は、起動すると**設定モード**になり、画面に設定用 Wi-Fi の名前
   （`m5-system-panel-XXXX`）と、使い捨てのパスワードを表示します。
2. Mac のメニューバーの Wi-Fi から、その名前のネットワークに接続します（パスワードは M5 の画面のもの）。
3. コンパニオンのメニューから「設定を始める…」を選び、窓で「パネルが見つけた Wi-Fi を表示」を押します。
4. パネルにつながせる Wi-Fi を選び、そのパスワードを入れて「パネルに設定を渡す」を押します。
5. パネルは再起動して家の Wi-Fi につなぎます。Mac の Wi-Fi は、設定用 Wi-Fi が消えると元のネットワークに戻ります。
6. 設定用 Wi-Fi はもう使いません。システム設定 › Wi-Fi › 既知のネットワーク で
   `m5-system-panel-XXXX` の「…」から「リストから削除」を選ぶと、保存されたパスワードごと消えます。

**設定をやり直す**には、M5 の B ボタンを押しながら電源を入れ、画面の案内が消えるまで 3 秒押し続けます。
パネルの設定が消え、設定モードになります。

## メニュー

| 項目 | 内容 |
|---|---|
| 状態 | 接続中（パネル XXXX）／パネル XXXX を探しています／パネル XXXX が応答しません／ローカルネットワークの許可が必要です／パネルのファームウェアが違います／未設定 |
| 明るさ | パネルの画面の明るさを 1（暗い）〜 5（明るい）から選ぶ。パネルが登録されているときに出る。v0.1.x のファームウェアのパネルにつながっている間は選べず、更新が必要と表示する |
| 設定を始める… | 設定の窓を開く。未設定のとき、または設定モードのパネルが見つかったときに出る |
| パネルの登録を解除 | この Mac に保存した鍵を消す（パネルを使うには設定をやり直す） |
| ログイン時に起動 | ログインしたときにコンパニオンを起動する |
| 終了 | コンパニオンを終了する |

## 保存されるものと消し方

| 保存先 | 内容 | 消し方 |
|---|---|---|
| Mac のログインキーチェーン（項目「m5-system-panel (active)」） | パネルの ID と鍵。iCloud では同期されません | メニューの「パネルの登録を解除」 |
| Mac の UserDefaults（`jp.nlink.m5-system-panel` の `brightness`） | 明るさの段階 | `defaults delete jp.nlink.m5-system-panel brightness`（次に起動したとき段階 3 に戻る） |
| M5 のフラッシュ（NVS） | 家の Wi-Fi の名前とパスワード、パネルの ID と鍵 | B を押しながら電源を入れて 3 秒。M5 を手放すときは `esptool … erase-flash` |

パネルの NVS は暗号化されていません。鍵と Wi-Fi のパスワードはフラッシュに平文で入ります。

## 安全について

- パネルに表示されるのは、設定で鍵を共有した Mac の値だけです。値は暗号化して送り、
  鍵の合わないもの・改ざんされたもの・録って送り直したものは捨てます。
- 同じネットワークの悪意ある相手が、表示を**止める**ことは防げません（偽の値を表示させることはできません）。
- 設定時のやり取りは、設定用 Wi-Fi（画面にだけ出る使い捨てのパスワード）の暗号だけで守られます。

## 文書

- [通信仕様](docs/ja/protocol.ja.md)
- [RFP（企画と設計の判断）](docs/ja/m5-system-panel-rfp.ja.md)
- ADR: [0001 実測から決めたこと](docs/ja/adr/0001-phase0-premises.ja.md)・[0002 暗号と設定時の相手](docs/ja/adr/0002-crypto-and-setup-binding.ja.md)・[0003 画面の明るさ](docs/ja/adr/0003-brightness.ja.md)

## ソースからのビルド

コンパニオン（Swift 6、Xcode のコマンドラインツール）:

```bash
make test        # 単体テスト
make build-app   # dist/M5SystemPanel.app（手元の Developer ID で署名）
```

ファームウェア（arduino-cli に `esp32:esp32` コア 3.3.8、M5Unified 0.2.14、M5GFX 0.2.27 を入れておく）:

```bash
make firmware                                   # dist/firmware/
make firmware-upload PORT=/dev/cu.usbserial-XXXX
```

## ライセンス

[MIT](LICENSE)
