import Foundation

/// File names that arrive from a server, checked before they become paths on this Mac.
enum SafeNames {
    /// A name from the server that can't climb out of the folder it's saved into on this Mac.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// `child` once its path is resolved, if it's still inside `folder`.
    static func contained(_ child: URL, in folder: URL) -> URL? {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = child.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasPrefix(base + "/") ? child : nil
    }
}
