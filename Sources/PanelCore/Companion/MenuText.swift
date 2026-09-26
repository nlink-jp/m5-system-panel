import Foundation

/// The companion's menu, as words (RFP §2 "Companion menu"). Pure, so every
/// status the supervisor can report has a tested line of text.
public enum MenuText {
    public static func status(registered: Registration?, supervisor: ConnectionSupervisor.Status) -> String {
        guard let registration = registered else { return "未設定" }
        switch supervisor {
        case .searching: return "パネル \(registration.deviceID) を探しています"
        case .connected: return "接続中（パネル \(registration.deviceID)）"
        case .notResponding: return "パネル \(registration.deviceID) が応答しません"
        case .permissionRequired: return "ローカルネットワークの許可が必要です"
        case .firmwareMismatch: return "パネルのファームウェアが違います"
        }
    }

    /// A second line for statuses that need the user to do something.
    public static func hint(supervisor: ConnectionSupervisor.Status) -> String? {
        switch supervisor {
        case .permissionRequired:
            return "システム設定 › プライバシーとセキュリティ › ローカルネットワーク で M5SystemPanel をオンに"
        case .firmwareMismatch:
            return "パネルとコンパニオンの版を揃えてください"
        default:
            return nil
        }
    }

    public static let startSetup = "設定を始める…"
    public static let unregister = "パネルの登録を解除"
    public static let launchAtLogin = "ログイン時に起動"
    public static let quit = "終了"
}
