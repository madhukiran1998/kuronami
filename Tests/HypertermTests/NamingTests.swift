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
}
