import Foundation

/// The Bonjour service the panel advertises and the companion browses for.
///
/// The same string is compiled into the firmware (`firmware/m5-system-panel/`)
/// and declared in `Info.plist` under `NSBonjourServices`; the three must agree
/// or discovery fails without an error that names the cause.
public enum PanelService {
    /// The service name, without the leading underscore (RFC 6763 §7).
    public static let name = "m5-system-panel"
    /// The DNS-SD service type as Network.framework and `NSBonjourServices` take it.
    public static let type = "_\(name)._tcp"
}

/// Whether `name` is a valid service name under RFC 6335 §5.1.
///
/// The rules, verbatim from the RFC: 1–15 characters; only US-ASCII letters,
/// digits and hyphens; at least one letter; no leading or trailing hyphen;
/// no two hyphens next to each other. Case is ignored for comparison, not for
/// validity, so both cases pass here.
public func isValidServiceName(_ name: String) -> Bool {
    let scalars = Array(name.unicodeScalars)
    guard (1...15).contains(scalars.count) else { return false }

    var sawLetter = false
    var previousWasHyphen = false
    for scalar in scalars {
        switch scalar {
        case "A"..."Z", "a"..."z":
            sawLetter = true
            previousWasHyphen = false
        case "0"..."9":
            previousWasHyphen = false
        case "-":
            if previousWasHyphen { return false }
            previousWasHyphen = true
        default:
            return false
        }
    }
    guard sawLetter else { return false }
    return scalars.first != "-" && scalars.last != "-"
}
