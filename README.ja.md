# m5-system-panel

[English](README.md)

机に置いた M5Stack BASIC を、1 台の Mac 専用の小さな計器盤にします。CPU・GPU・
メモリ・ネットワークを常時表示します。Mac のメニューバーに常駐するアプリ
（コンパニオン）が値を計測して Wi-Fi で送り、パネルは描画するだけです。3 つの
ボタンは表示ページの切り替えに使います。

> **状態:** 開発中です。リリースはまだありません。ソースからビルドしてください。

## できること

- **パネルに 5 ページ**: 4 項目の概要、CPU（全体とコアごと）、GPU、メモリ（内訳・圧迫度・
  スワップ）、ネットワーク（net-meter と同じく上りを上に赤で、下りを下に緑で描く）。
  A で前のページ、C で次のページ、B で概要に戻ります。
- **データは Wi-Fi で送る。** USB ケーブルは給電だけに使います。
- **あなたのパネルを動かせるのはあなたの Mac だけ。** 設定のときにパネルと
  コンパニオンで鍵を共有し、パネルはその鍵で送られていないものを無視します。
  同じネットワークに複数のパネルや Mac があっても混線しません。
- **設定はコンパニオンから。** 初回の起動時、パネルは一時的な Wi-Fi を出し、
  使い捨てのパスワードを画面に表示します。Mac からその Wi-Fi につなぎ、
  コンパニオンで設定を済ませます。

## 動作環境

- M5Stack BASIC v2.7
- Apple Silicon の Mac、macOS 26 以降
- 機器どうしが通信できる 2.4 GHz の Wi-Fi（WPA2 または WPA3 パーソナル）

## ソースからのビルド

コンパニオン（Swift 6、Xcode のコマンドラインツール）:

```bash
make test        # 単体テスト
make build-app   # dist/M5SystemPanel.app（手元の Developer ID で署名）
```

ファームウェア（arduino-cli に `esp32:esp32` コア 3.3.8、M5Unified 0.2.14、
M5GFX 0.2.27 を入れておく）:

```bash
make firmware                                   # dist/firmware/
make firmware-upload PORT=/dev/cu.usbserial-XXXX
```

## ライセンス

[MIT](LICENSE)
