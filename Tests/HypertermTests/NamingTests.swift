import XCTest
@testable import Hyperterm

final class NamingTests: XCTestCase {
    func testUnnamedTerminalsAreAgentRenamable() {
        let spec = LaunchSpec(label: "", kind: .claude, cwd: "~")
        XCTAssertEqual(spec.labelSource, .auto)
        XCTAssertTrue(spec.agentMayRename)
    }

    func testUserNamedTerminalsAreNot() {
        let spec = LaunchSpec(label: "API", kind: .claude, cwd: "~")
        XCTAssertEqual(spec.label, "api")
        XCTAssertEqual(spec.labelSource, .user)
        XCTAssertFalse(spec.agentMayRename)
    }

    func testSpecsSavedBeforeLabelSourcesCountAsUserNamed() throws {
        let legacy = """
        {"id":"7B4C9E0A-1F2B-4C3D-9E8F-0A1B2C3D4E5F","label":"web","kind":"server","cwd":"~","createdAt":"2026-10-02T20:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let spec = try decoder.decode(LaunchSpec.self, from: Data(legacy.utf8))
        XCTAssertNil(spec.labelSource)
        XCTAssertFalse(spec.agentMayRename)
    }

    func testLaunchReservationsProtectAddressesBeforeSessionsExist() {
        var reservations = SessionLabelReservations()
        let first = UUID(), second = UUID(), third = UUID()
        let occupied: Set<String> = ["api", "api-2"]
        XCTAssertEqual(reservations.reserve("api", for: first, occupied: occupied), "api-3")
        XCTAssertEqual(reservations.reserve("api", for: second, occupied: occupied), "api-4")
        XCTAssertTrue(reservations.contains("api-3"))
        XCTAssertEqual(reservations.occupied(excluding: first), ["api-4"])

        reservations.release(first)
        XCTAssertFalse(reservations.contains("api-3"))
        XCTAssertEqual(reservations.reserve("api", for: third, occupied: occupied), "api-3")
        XCTAssertEqual(reservations.reserve("api", for: second, occupied: occupied), "api-4")
    }

    func testCompletedLaunchStillKeepsItsAddressTaken() {
        var reservations = SessionLabelReservations()
        let first = UUID(), next = UUID()
        XCTAssertEqual(reservations.reserve("agent", for: first, occupied: []), "agent")
        reservations.release(first)
        XCTAssertEqual(reservations.reserve("agent", for: next, occupied: ["agent"]), "agent-2")
    }

    func testOptionalIsolationLoadsConfigOutsideRepositoryWithoutWarning() async throws {
        let folder = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = "{\"dev\":\"npm run dev -- --port $PORT\",\"setup\":\"npm install\",\"ports\":[4200,4299]}"
        try Data(json.utf8).write(to: folder.appendingPathComponent(".hyperterm.json"))
        let spec = LaunchSpec(label: "fixture", kind: .claude, cwd: folder.path)

        let result = await SessionLaunchPreparation.prepare(spec, isolateIfPossible: true)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.spec, spec)
        XCTAssertEqual(result.config?.dev, "npm run dev -- --port $PORT")
        XCTAssertEqual(result.config?.ports, [4200, 4299])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude").path))
    }

    func testExplicitIsolationFailureRetainsFallbackAndWarning() async throws {
        let folder = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = LaunchSpec(label: "fixture", kind: .codex, cwd: folder.path)

        let result = await SessionLaunchPreparation.prepare(spec, worktree: true)

        XCTAssertEqual(result.spec, spec)
        XCTAssertTrue(result.error?.contains("Worktree not created") == true)
        XCTAssertTrue(result.error?.contains("Started in") == true)
        XCTAssertNil(result.config)
    }

    func testResumePreservesExistingWorkspaceWithoutRecreatingIt() async throws {
        let folder = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        var spec = LaunchSpec(label: "fixture", kind: .claude, cwd: folder.path)
        spec.worktreeName = "existing-worktree"
        spec.worktreeBranch = "worktree-existing-worktree"

        let result = await SessionLaunchPreparation.prepare(spec, resume: true, worktree: true)

        XCTAssertEqual(result.spec, spec)
        XCTAssertNil(result.error)
    }

    private func temporaryProject() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuronami-launch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
