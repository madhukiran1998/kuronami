import Foundation
import XCTest
@testable import Hyperterm

final class WorktreeFactoryTests: XCTestCase {
    private var base: String!
    private var repo: String { base + "/main" }

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "kuronami-worktrees-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertNotNil(Git.run(["init", "-q", "-b", "main"], at: repo))
        try write(repo, ".gitignore", "node_modules/\n.env\nbuild/\n")
        try write(repo, "shared.txt", "one\ntwo\nthree\n")
        XCTAssertNotNil(Git.run(["add", "-A"], at: repo))
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", "first"], at: repo, environment: Git.identity))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private func write(_ root: String, _ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func addWorktree(_ name: String) -> String {
        let path = base + "/" + name
        XCTAssertNotNil(Git.run(["worktree", "add", "-q", "-b", name, path, "HEAD"], at: repo))
        return path
    }

    // MARK: - .worktreeinclude

    func testNoIncludeFileMeansNothingIsCopied() throws {
        try write(repo, "node_modules/a/index.js", "x")
        XCTAssertEqual(WorktreeInclude.entries(root: repo), [])
    }

    func testIncludeListsMatchingFoldersWholeAndSkipsTheRest() throws {
        try write(repo, "node_modules/a/index.js", "x")
        try write(repo, "packages/p/node_modules/b/index.js", "y")
        try write(repo, ".env", "SECRET=1")
        try write(repo, "build/out.o", "z")
        try write(repo, ".worktreeinclude", "# dependencies\nnode_modules/\n\n.env\n")
        XCTAssertEqual(Set(WorktreeInclude.entries(root: repo)), [".env", "node_modules/", "packages/p/node_modules/"])
    }

    func testWarmClonesIncludedEntriesIntoANewWorktree() throws {
        try write(repo, "node_modules/a/index.js", "module")
        try write(repo, ".env", "SECRET=1")
        try write(repo, "build/out.o", "z")
        try write(repo, ".worktreeinclude", "node_modules\n.env\n")
        let worktree = addWorktree("alpha")
        let result = WorktreeInclude.warm(worktree)
        XCTAssertEqual(Set(result.copied), [".env", "node_modules"])
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(try String(contentsOfFile: worktree + "/node_modules/a/index.js", encoding: .utf8), "module")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + "/build"))
        // Already there: left alone.
        XCTAssertEqual(WorktreeInclude.warm(worktree).copied, [])
    }

    // MARK: - Ports

    func testSlotsTakeTheLowestFreeAndKeepTheirOwn() {
        XCTAssertEqual(PortSlots.assign(current: nil, taken: []), 0)
        XCTAssertEqual(PortSlots.assign(current: nil, taken: [0, 1, 3]), 2)
        XCTAssertEqual(PortSlots.assign(current: 5, taken: [0, 1]), 5)
        XCTAssertEqual(PortSlots.assign(current: 1, taken: [0, 1]), 2)
        XCTAssertEqual(PortSlots.range(2), 4120...4129)
    }

    func testSlotEnvironment() {
        var spec = LaunchSpec(label: "a", kind: .codex, cwd: "/tmp")
        XCTAssertEqual(PortSlots.environment(for: spec), [:])
        spec.portSlot = 3
        XCTAssertEqual(PortSlots.environment(for: spec), ["KURONAMI_PORT": "4130", "PORT": "4130"])
    }

    // MARK: - Conflict watch

    func testOverlapsFindUncommittedConflictsBetweenWorktrees() throws {
        let alpha = addWorktree("alpha")
        let bravo = addWorktree("bravo")
        let charlie = addWorktree("charlie")
        try write(alpha, "shared.txt", "one\nALPHA\nthree\n")
        try write(bravo, "shared.txt", "one\nBRAVO\nthree\n")
        try write(charlie, "other.txt", "new\n")
        let (a, b, c) = (UUID(), UUID(), UUID())
        let pairs = Overlaps.scan([(a, alpha), (b, bravo), (c, charlie)], focus: [a])
        XCTAssertEqual(pairs.first { $0.a == a && $0.b == b }?.files, ["shared.txt"])
        XCTAssertEqual(pairs.first { $0.a == a && $0.b == c }?.files, [])
        XCTAssertNil(pairs.first { $0.a == b && $0.b == c }, "pairs without a finished agent aren't scanned")
        // Nothing was written to the worktrees, their indexes or refs.
        XCTAssertEqual(Git.run(["status", "--porcelain"], at: alpha), "M shared.txt")
        XCTAssertEqual(Git.run(["for-each-ref", "--format=%(refname)"], at: repo)?.contains("kuronami"), false)
    }

    func testNotesGoOutOnlyForNewFiles() {
        var notes = OverlapNotes()
        let (a, b) = (UUID(), UUID())
        XCTAssertTrue(notes.shouldTell(a, b, files: ["x.swift"]))
        XCTAssertFalse(notes.shouldTell(a, b, files: ["x.swift"]))
        XCTAssertFalse(notes.shouldTell(b, a, files: ["x.swift"]), "either direction is the same pair")
        XCTAssertTrue(notes.shouldTell(a, b, files: ["x.swift", "y.swift"]))
        XCTAssertFalse(notes.shouldTell(a, b, files: ["y.swift"]))
        XCTAssertTrue(notes.shouldTell(a, UUID(), files: ["x.swift"]))
    }
}
