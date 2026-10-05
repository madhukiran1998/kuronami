import Foundation

/// Which files two agents' workspaces would conflict on if merged, as they stand right now:
/// uncommitted work included. Each workspace is snapshotted (as checkpoints are) into a scratch
/// object store, then `git merge-tree` merges the snapshots against their merge base without
/// touching any worktree, index or ref. Calls block; run them off the main thread.
enum Overlaps {
    struct Pair: Equatable {
        let a: UUID
        let b: UUID
        let files: [String]
    }

    /// Every pair of distinct workspaces that includes one in `focus`, with its conflicting files
    /// (empty when the two merge cleanly). All workspaces must belong to one repository.
    static func scan(_ workspaces: [(id: UUID, path: String)], focus: Set<UUID>) -> [Pair] {
        guard let first = workspaces.first else { return [] }
        return Checkpoints.withScratchObjects(at: first.path) { environment in
            var snapshots: [UUID: String] = [:]
            for workspace in workspaces {
                snapshots[workspace.id] = Checkpoints.snapshot(at: workspace.path, message: "Kuronami: overlap", environment: environment)
            }
            var pairs: [Pair] = []
            for (index, a) in workspaces.enumerated() {
                for b in workspaces[(index + 1)...] where focus.contains(a.id) || focus.contains(b.id) {
                    guard a.path != b.path, let left = snapshots[a.id], let right = snapshots[b.id],
                          let files = conflicts(left, right, at: a.path, environment: environment) else { continue }
                    pairs.append(Pair(a: a.id, b: b.id, files: files))
                }
            }
            return pairs
        }
    }

    /// Files a merge of two commits would leave conflicted, or nil when Git can't tell (no
    /// common history). merge-tree exits 1 on conflicts, which `Git.run` would report as failure.
    static func conflicts(_ left: String, _ right: String, at path: String, environment extra: [String: String]) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false",
                             "merge-tree", "--write-tree", "--name-only", "--no-messages", left, right]
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return []
        case 1:
            // The merged tree's id, then one conflicted path per line.
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            return lines.dropFirst().prefix { !$0.isEmpty }.map(String.init)
        default: return nil
        }
    }
}

/// Which overlaps an agent has already been told about, so a note goes out only when a pair
/// starts conflicting on a file it hadn't before.
struct OverlapNotes {
    private var told: [Set<UUID>: Set<String>] = [:]

    mutating func shouldTell(_ a: UUID, _ b: UUID, files: [String]) -> Bool {
        let pair: Set<UUID> = [a, b]
        let fresh = Set(files).subtracting(told[pair, default: []])
        guard !fresh.isEmpty else { return false }
        told[pair, default: []].formUnion(fresh)
        return true
    }
}
