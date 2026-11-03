import Foundation

/// How loud a log line is, read from the words in it: `ERROR`, `level=warn`, a 5xx in an access log.
enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warning, error

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    private static let colours = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\r")
    private static let errorWords = try! NSRegularExpression(pattern: #"\b(fatal|panic|emerg|alert|crit(ical)?|err(or)?|exception|traceback|failed|failure)\b|" 5\d\d |\blevel=(error|fatal)"#, options: .caseInsensitive)
    private static let warningWords = try! NSRegularExpression(pattern: #"\b(warn(ing)?|deprecated)\b|" 4\d\d |\blevel=warn"#, options: .caseInsensitive)
    private static let debugWords = try! NSRegularExpression(pattern: #"\b(debug|trace)\b|\blevel=(debug|trace)"#, options: .caseInsensitive)

    /// Without colour codes and carriage returns.
    static func clean(_ text: String) -> String {
        colours.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func of(_ text: String) -> LogLevel {
        let range = NSRange(text.startIndex..., in: text)
        if errorWords.firstMatch(in: text, range: range) != nil { return .error }
        if warningWords.firstMatch(in: text, range: range) != nil { return .warning }
        if debugWords.firstMatch(in: text, range: range) != nil { return .debug }
        return .info
    }
}
