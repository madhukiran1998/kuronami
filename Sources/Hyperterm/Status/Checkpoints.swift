import Foundation

/// Snapshots of an agent's workspace at each turn boundary, kept as hidden Git commits under
/// `refs/kuronami/<session>/`. A snapshot is built in a throwaway index, so the user's index,
/// HEAD, branches and stash are never touched, and .gitignored files are left out.
///
/// That gives three things the agent CLIs don't: the diff of exactly one turn, reverting files to
/// how they were before any turn, and undoing that revert (every restore snapshots first).
/// All calls block; run them off the main thread.
enum Checkpoints {
    struct Turn: Equatable, Identifiable {
        /// 1-based, in the order turns started.
        let index: Int
        let prompt: String
        let date: Date
        /// The workspace when the turn began.
        let start: String
        /// The workspace when it ended; nil while it is still running.
        var end: String?

        var id: Int { index }
    }

    enum Phase: String { case start, end }

    static let namespace = "refs/kuronami"

    static func prefix(session: String) -> String { "\(namespace)/\(session)/" }

    static func ref(session: String, turn: Int, phase: Phase) -> String {
        // Zero-padded so refs sort in turn order.
        prefix(session: session) + String(format: "%04d-%@", turn, phase.rawValue)
    }

    // MARK: - Capture

    /// Snapshots the working tree (tracked and untracked, minus ignored files) as a commit whose
    /// parent is HEAD. Returns its hash, or nil outside a repository.
    static func snapshot(at path: String, message: String) -> String? {
        guard let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], at: path) else { return nil }
        let index = (gitDir as NSString).appendingPathComponent("kuronami-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE": index]
        let head = Git.run(["rev-parse", "--verify", "-q", "HEAD"], at: path)
        if head != nil { _ = Git.run(["read-tree", "HEAD"], at: path, environment: environment) }
        guard Git.run(["add", "-A", "."], at: path, environment: environment) != nil,
              let tree = Git.run(["write-tree"], at: path, environment: environment) else { return nil }
        var args = ["commit-tree", tree, "-m", message.isEmpty ? "Kuronami checkpoint" : message]
        if let head { args += ["-p", head] }
        return Git.run(args, at: path, environment: Git.identity)
    }

    /// Snapshots and records the snapshot as `turn`'s start or end.
    @discardableResult
    static func capture(at path: String, session: String, turn: Int, phase: Phase, prompt: String) -> String? {
        guard let commit = snapshot(at: path, message: prompt) else { return nil }
        let name = ref(session: session, turn: turn, phase: phase)
        return Git.run(["update-ref", name, commit], at: path) != nil ? commit : nil
    }

    // MARK: - Reading

    /// Every recorded turn, oldest first.
    static func turns(at path: String, session: String) -> [Turn] {
        let format = "%(refname)%09%(objectname)%09%(committerdate:unix)%09%(contents:subject)"
        guard let listing = Git.run(["for-each-ref", "--format=" + format, prefix(session: session)], at: path) else { return [] }
        var starts: [Int: (commit: String, date: Date, prompt: String)] = [:]
        var ends: [Int: String] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            let name = (fields[0] as NSString).lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count == 2, let turn = Int(parts[0]) else { continue }
            if parts[1] == "start" {
                starts[turn] = (fields[1], Date(timeIntervalSince1970: Double(fields[2]) ?? 0), fields.count > 3 ? fields[3] : "")
            } else if parts[1] == "end" {
                ends[turn] = fields[1]
            }
        }
        return starts.keys.sorted().compactMap { index in
            guard let start = starts[index] else { return nil }
            return Turn(index: index, prompt: start.prompt, date: start.date, start: start.commit, end: ends[index])
        }
    }

    /// The next turn number for a session.
    static func nextTurn(at path: String, session: String) -> Int {
        (turns(at: path, session: session).last?.index ?? 0) + 1
    }

    /// Files changed between two snapshots, or between a snapshot and the live workspace.
    static func changedFiles(at path: String, from: String, to: String?) -> [String] {
        let target = to ?? snapshot(at: path, message: "Kuronami: compare")
        guard let target else { return [] }
        return (Git.run(["diff", "--name-only", "--no-renames", from, target], at: path) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// A unified diff between two snapshots, or between a snapshot and the live workspace.
    static func diff(at path: String, from: String, to: String?) -> String {
        guard let target = to ?? snapshot(at: path, message: "Kuronami: compare") else { return "" }
        return Git.run(["-c", "core.quotePath=false", "diff", "--no-renames", from, target], at: path, trim: false) ?? ""
    }

    // MARK: - Restoring

    /// Puts the workspace's files back the way they were in `commit`. Files that didn't exist
    /// then are removed; ignored files are left alone. The index, HEAD and branches aren't
    /// touched. Returns a snapshot of the workspace from just before, so the restore can itself
    /// be undone.
    static func restore(at path: String, to commit: String, session: String) -> Result<String, CheckpointError> {
        guard let before = snapshot(at: path, message: "Before restoring a checkpoint") else {
            return .failure(.notARepository)
        }
        _ = Git.run(["update-ref", prefix(session: session) + "undo", before], at: path)
        let added = (Git.run(["diff", "--name-only", "--no-renames", "--diff-filter=A", commit, before], at: path) ?? "")
            .split(separator: "\n").map(String.init)
        guard let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], at: path) else { return .failure(.notARepository) }
        let index = (gitDir as NSString).appendingPathComponent("kuronami-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE": index]
        guard Git.run(["read-tree", commit], at: path, environment: environment) != nil,
              Git.run(["checkout-index", "-a", "-f"], at: path, environment: environment) != nil else {
            return .failure(.git("couldn't write the checkpoint's files"))
        }
        let root = Git.run(["rev-parse", "--show-toplevel"], at: path) ?? path
        for file in added {
            let full = (root as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: full)
            removeEmptyParents(of: full, upTo: root)
        }
        return .success(before)
    }

    /// The snapshot taken before the most recent restore, if any.
    static func undoPoint(at path: String, session: String) -> String? {
        Git.run(["rev-parse", "--verify", "-q", prefix(session: session) + "undo"], at: path)
    }

    /// Deletes a session's checkpoints (when it's closed or its worktree archived).
    static func prune(at path: String, session: String) {
        guard let listing = Git.run(["for-each-ref", "--format=%(refname)", prefix(session: session)], at: path) else { return }
        for name in listing.split(separator: "\n") { _ = Git.run(["update-ref", "-d", String(name)], at: path) }
    }

    private static func removeEmptyParents(of file: String, upTo root: String) {
        var directory = (file as NSString).deletingLastPathComponent
        while directory.count > root.count, directory.hasPrefix(root),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: directory), contents.isEmpty {
            try? FileManager.default.removeItem(atPath: directory)
            directory = (directory as NSString).deletingLastPathComponent
        }
    }
}

enum CheckpointError: Error, Equatable, CustomStringConvertible {
    case notARepository
    case git(String)

    var description: String {
        switch self {
        case .notARepository: return "this folder isn't a Git repository"
        case .git(let message): return message
        }
    }
}

/// A small Git runner with its own environment, independent of AppKit so the logic built on it
/// is tested anywhere Git is installed.
enum Git {
    static let executable = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    /// Snapshots need an author even on machines with no Git identity configured.
    static let identity = [
        "GIT_AUTHOR_NAME": "Kuronami", "GIT_AUTHOR_EMAIL": "kuronami@localhost",
        "GIT_COMMITTER_NAME": "Kuronami", "GIT_COMMITTER_EMAIL": "kuronami@localhost",
    ]

    /// Output (trimmed unless `trim` is false), or nil when Git fails.
    static func run(_ arguments: [String], at path: String, environment extra: [String: String] = [:],
                    trim: Bool = true, timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // No hooks or fsmonitor: snapshots must never run repository code.
        process.arguments = ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                             "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}
