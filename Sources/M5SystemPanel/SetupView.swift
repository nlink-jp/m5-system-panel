import PanelCore
import SwiftUI

/// The setup window (protocol v1 §5.2): choose the home Wi-Fi the panel should
/// join, enter its password, and hand them over. The key never appears here.
struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selected: [UInt8]?
    @State private var typedSSID = ""
    @State private var password = ""
    @State private var openNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.setupPhase {
            case .idle:
                Text("設定中のパネルが見つかりません。")
                Text("パネルを設定モードにし（B を押しながら電源を入れて 3 秒）、画面の Wi-Fi にこの Mac からつないでください。")
                    .foregroundStyle(.secondary)
            case .offered(let id):
                Text("パネル \(id) が見つかりました。")
                Button("パネルが見つけた Wi-Fi を表示") { model.startSetup() }
                    .keyboardShortcut(.defaultAction)
            case .listing:
                ProgressView("Wi-Fi の一覧を受け取っています…")
            case .choosing(let networks):
                chooser(networks)
            case .joining:
                ProgressView("パネルに設定を渡しています…")
            case .finished(let id):
                Text("パネル \(id) を設定しました。").font(.headline)
                Text("パネルは再起動して家の Wi-Fi につなぎます。この Mac の Wi-Fi は、設定用 Wi-Fi が消えると元のネットワークに戻ります。")
                Text("設定用 Wi-Fi はもう使いません。システム設定 › Wi-Fi の「既知のネットワーク」から削除できます。")
                    .foregroundStyle(.secondary)
                Button("閉じる") {
                    model.dismissSetupResult()
                    dismissWindow(id: "setup")
                }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red)
                Button("閉じる") {
                    model.dismissSetupResult()
                    dismissWindow(id: "setup")
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private func chooser(_ networks: [ScannedNetwork]) -> some View {
        Text("パネルがつなぐ Wi-Fi（2.4 GHz）").font(.headline)
        List(selection: $selected) {
            ForEach(networks, id: \.ssid) { network in
                HStack {
                    Text(displayName(network.ssid))
                    Spacer()
                    Text("\(network.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                    if network.security == .open { Text("認証なし").foregroundStyle(.secondary) }
                }
                .tag(Optional(network.ssid))
            }
        }
        .frame(height: 180)
        TextField("一覧にないときは名前を入力", text: $typedSSID)
        Toggle("認証なしのネットワーク", isOn: $openNetwork)
        if !openNetwork {
            SecureField("パスワード", text: $password)
        }
        HStack {
            Spacer()
            Button("パネルに設定を渡す") {
                let ssid = typedSSID.isEmpty ? selected : Array(typedSSID.utf8)
                guard let ssid else { return }
                model.join(ssid: ssid, password: openNetwork ? nil : Array(password.utf8))
                password = ""
            }
            .keyboardShortcut(.defaultAction)
            // WPA2/WPA3 personal passphrases are 8–63 characters.
            .disabled((typedSSID.isEmpty && selected == nil) || (!openNetwork && !(8...63).contains(password.utf8.count)))
        }
    }

    private func displayName(_ ssid: [UInt8]) -> String {
        String(validating: ssid, as: UTF8.self) ?? ssid.map { String(format: "%02x", $0) }.joined()
    }
}
