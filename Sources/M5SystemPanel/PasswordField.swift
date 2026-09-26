import AppKit
import SwiftUI

/// A password field that switches the keyboard to a Roman input source while it
/// has focus, as Mac password fields do.
///
/// A WPA2/WPA3 passphrase is printable ASCII. SwiftUI's SecureField left a
/// Japanese input source active and every keystroke beeped, with nothing on
/// screen saying why (end-to-end test, 2026-09-27). The documented mechanism is
/// the input context's `allowedInputSourceLocales` set to
/// `NSAllRomanInputSourcesLocaleIdentifier`, which restricts the allowed input
/// sources to Roman ones while that context is active (NSTextInputContext).
struct PasswordField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> RomanSecureTextField {
        let field = RomanSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: RomanSecureTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

final class RomanSecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The field editor is what receives the keys; restrict its input context.
        if became { currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier] }
        return became
    }
}
