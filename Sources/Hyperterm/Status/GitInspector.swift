import Foundation

struct GitInfo: Equatable {
    /// The main checkout's root (a worktree's parent repository).
    static func mainRoot(_ info: GitInfo) -> String { info.mainRoot }

    /// Main repository name, shared by its worktrees, used to group sessions by project.
    var project: String
    var branch: String
    var root: String
    var isWorktree: Bool
    var mainRoot: String
}

/// Git facts for a directory, cached briefly; `git` is cheap but runs per session per poll.
final class GitInspector: @unchecked Sendable {
    private var cache: [String: (info: GitInfo?, at: Date)] = [:]
    private let lock = NSLock()

    func info(for directory: String) -> GitInfo? {
        lock.lock()
        if let hit = cache[directory], Date().timeIntervalSince(hit.at) < 8 {
            lock.unlock()
            return hit.info
        }
        lock.unlock()
        let info = Self.query(directory)
        let now = Date()
        lock.lock()
        // Entries for folders no session polls any more (closed sessions, archived worktrees).
        cache = cache.filter { now.timeIntervalSince($0.value.at) < 120 }
        cache[directory] = (info, now)
        lock.unlock()
        return info
    }

    static func query(_ directory: String) -> GitInfo? {
        let output = runGit(["-C", directory, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD", "--git-common-dir"])
        let lines = output?.split(separator: "\n").map(String.init) ?? []
        guard lines.count >= 3 else { return nil }
        let root = lines[0]
        // --git-common-dir is ".git" for the main checkout, or the main repo's .git for a worktree.
        let common = lines[2].hasPrefix("/") ? lines[2] : (root as NSString).appendingPathComponent(lines[2])
        let mainRoot = (common as NSString).deletingLastPathComponent
        let isWorktree = URL(fileURLWithPath: mainRoot).standardized.path != URL(fileURLWithPath: root).standardized.path
        return GitInfo(project: URL(fileURLWithPath: mainRoot).lastPathComponent, branch: lines[1], root: root,
                       isWorktree: isWorktree, mainRoot: isWorktree ? mainRoot : root)
    }
}

/// Runs git with repo-supplied hooks and fsmonitor disabled: Hyperterm runs git inside
/// agent-controlled repos and must not execute their config.
func runGit(_ arguments: [String]) -> String? {
    let safety = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
    return runProcess("/usr/bin/git", safety + arguments, timeout: 15)?.trimmingCharacters(in: .whitespacesAndNewlines)
}
