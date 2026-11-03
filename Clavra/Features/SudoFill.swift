import Foundation
import LocalAuthentication

/// sudo asking for a password, answered from the Keychain once Touch ID (or the Mac's password)
/// says it's you. The password goes straight to the server: it's never typed, so it never lands in
/// the scrollback, the history or a broadcast to other panes.
enum SudoFill {
    /// Where the password comes from.
    enum Source: Equatable {
        /// Saved earlier for this host.
        case saved
        /// The password this host signs in with; often the same one.
        case signIn
        /// Typed into Clavra's field just now, kept for next time when `remember` is on.
        case typed(String, remember: Bool)
    }

    private static let prompts: [NSRegularExpression] = [
        #"^\[sudo\] password for [^:\s]+:\s*$"#,
        #"^\[sudo: authenticate\] Password:\s*$"#,
        #"^Password:\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The line under the cursor is sudo's password prompt. A bare `Password:` only counts right
    /// after a command that started with sudo, so `su` or a program's own prompt are left alone.
    static func isPrompt(_ line: String, after command: String?) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(text.startIndex..., in: text)
        for (index, regex) in prompts.enumerated() where regex.firstMatch(in: text, range: range) != nil {
            if index < 2 { return true }
            let words = (command ?? "").split(separator: " ")
            return words.first == "sudo" || (words.first == "exec" && words.dropFirst().first == "sudo")
        }
        return false
    }

    /// Touch ID, or the Mac's own password where there's no Touch ID.
    @MainActor
    static func unlock(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Type It Myself"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
