import Foundation

/// Base64 of RFC 4648 §4, accepting only the canonical form (protocol v1 §1).
///
/// RFC 4648 §3.5 lets a decoder reject encodings whose pad bits are not zero; the
/// protocol makes that mandatory so two implementations never disagree about
/// which lines are valid. The check is "decode, re-encode, compare": any input
/// that survives is the one encoding of its bytes.
public enum StrictBase64 {
    public static func encode(_ bytes: some DataProtocol) -> String {
        Data(bytes).base64EncodedString()
    }

    /// The decoded bytes, or nil for anything but a canonical, non-empty encoding.
    public static func decode(_ text: some StringProtocol) -> [UInt8]? {
        guard !text.isEmpty, text.utf8.count % 4 == 0 else { return nil }
        let string = String(text)
        guard let data = Data(base64Encoded: string), !data.isEmpty,
              data.base64EncodedString() == string else { return nil }
        return Array(data)
    }
}
