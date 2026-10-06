import Foundation

/// What an agent asks Tako's browser to open: a URL, an address as typed in the bar, or a path to
/// a local file (an HTML artifact). Paths are resolved here, in the caller's directory, because
/// the app doesn't know where the agent was standing.
enum BrowserTarget {
    /// A `file://` URL when `raw` names an existing file, nil otherwise (it's a web address).
    static func fileURL(_ raw: String, cwd: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("file://") { return URL(string: text) }
        guard !text.contains("://") else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        let standardized = (path as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: standardized)
    }

    /// The address to send the app: the file's URL when it's a local file, else `raw` as given.
    static func address(_ raw: String, cwd: String) -> String {
        fileURL(raw, cwd: cwd)?.absoluteString ?? raw.trimmingCharacters(in: .whitespaces)
    }

    /// Only pages are opened this way: no javascript:, data: or custom schemes.
    static func isAllowed(_ url: URL) -> Bool {
        ["http", "https", "file", "about"].contains(url.scheme?.lowercased() ?? "")
    }
}
