import Foundation

/// What closing or archiving an agent's worktree would put at risk: files that aren't committed
/// and commits that aren't in the base branch yet. Measured against the base branch (not the
/// moment the worktree was made), so work that already landed, squash-merged included, never
/// counts. Calls block; run them off the main thread.
struct WorkAtRisk: Equatable {
    var uncommitted: Int
    var unmerged: Int

    var isEmpty: Bool { uncommitted == 0 && unmerged == 0 }

    /// "3 files aren't committed", "1 commit isn't in main yet", or both joined.
    func headline(base: String?) -> String {
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) file\(uncommitted == 1 ? " isn't" : "s aren't") committed") }
        if unmerged > 0 { parts.append("\(unmerged) commit\(unmerged == 1 ? " isn't" : "s aren't") in \(base ?? "the base branch") yet") }
        let text = parts.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Nil when git can't tell (no such folder, not a repository).
    static func evaluate(at path: String, base: String?) -> WorkAtRisk? {
        guard FileManager.default.fileExists(atPath: path),
              let status = runGit(["-C", path, "status", "--porcelain"]) else { return nil }
        let uncommitted = status.split(separator: "\n").count
        return WorkAtRisk(uncommitted: uncommitted, unmerged: unmergedCommits(at: path, base: base))
    }

    /// Commits on HEAD that the base doesn't have. `git cherry` skips ones the base has under
    /// another hash (cherry-picks, rebases). A squash merge leaves no matching commits, so a
    /// branch whose merge into the base would change nothing counts as landed.
    static func unmergedCommits(at path: String, base: String?) -> Int {
        guard let base = resolvedBase(at: path, base) else { return 0 }
        let cherry = runGit(["-C", path, "cherry", base, "HEAD"]) ?? ""
        let ahead = cherry.split(separator: "\n").filter { $0.hasPrefix("+") }.count
        guard ahead > 0 else { return 0 }
        if let merged = runGit(["-C", path, "merge-tree", "--write-tree", "--no-messages", base, "HEAD"])?
            .split(separator: "\n").first,
           let baseTree = runGit(["-C", path, "rev-parse", "\(base)^{tree}"]),
           String(merged) == baseTree {
            return 0
        }
        return ahead
    }

    /// The base to compare with: the one the agent was started from, else main or master.
    private static func resolvedBase(at path: String, _ base: String?) -> String? {
        for candidate in [base, "main", "master"].compactMap({ $0 }) where
            runGit(["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"]) != nil {
            return candidate
        }
        return nil
    }
}
