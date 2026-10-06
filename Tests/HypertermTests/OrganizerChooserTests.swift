import XCTest
@testable import Hyperterm

@MainActor
final class OrganizerChooserTests: XCTestCase {
    func testKeysMap() {
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 126, characters: nil), .up)
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 125, characters: nil), .down)
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 36, characters: "\r"), .confirm)
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 76, characters: nil), .confirm)
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 53, characters: nil), .back)
        XCTAssertEqual(OrganizerChooserKey.from(keyCode: 18, characters: "1"), .number(1))
        XCTAssertNil(OrganizerChooserKey.from(keyCode: 29, characters: "0"))
        XCTAssertNil(OrganizerChooserKey.from(keyCode: 0, characters: "a"))
    }

    func testArrowsMoveWithinBoundsAndSkipDisabledRows() {
        var model = OrganizerChooserModel()
        XCTAssertEqual(model.handle(.up, count: 3), .none)
        XCTAssertEqual(model.selection, 0)
        _ = model.handle(.down, count: 3, isEnabled: { $0 != 1 })
        XCTAssertEqual(model.selection, 2)
        _ = model.handle(.down, count: 3)
        XCTAssertEqual(model.selection, 2)
    }

    func testReturnPicksSelectionAndNumbersPickDirectly() {
        var model = OrganizerChooserModel(step: nil, selection: 1)
        XCTAssertEqual(model.handle(.confirm, count: 3), .pick(1))
        XCTAssertEqual(model.handle(.number(3), count: 3), .pick(2))
        XCTAssertEqual(model.selection, 2)
        XCTAssertEqual(model.handle(.number(4), count: 3), .none)
        XCTAssertEqual(model.handle(.number(1), count: 3, isEnabled: { $0 != 0 }), .none)
        XCTAssertEqual(model.handle(.back, count: 3), .back)
    }

    func testModelStepPreselectsTheRecommendedModel() {
        let model = OrganizerChooserModel.models(for: .codex)
        XCTAssertEqual(SessionStore.organizerModels(for: .codex)[model.selection].recommended, true)
    }

    func testFailedModelIsNotOfferedFirst() {
        let model = OrganizerChooserModel.models(for: .codex, notice: "x", avoiding: "gpt-6-luna")
        XCTAssertNotEqual(SessionStore.organizerModels(for: .codex)[model.selection].name, "gpt-6-luna")
        XCTAssertEqual(model.notice, "x")
    }

    func testSoleInstalledCLISkipsTheCLIStep() {
        XCTAssertEqual(OrganizerOnboarding.soleCLI(installed: [.codex]), .codex)
        XCTAssertNil(OrganizerOnboarding.soleCLI(installed: [.codex, .claude]))
        XCTAssertNil(OrganizerOnboarding.soleCLI(installed: []))
        XCTAssertNil(OrganizerOnboarding.soleCLI(installed: nil))
    }

    func testStartVerdicts() {
        typealias O = OrganizerOnboarding
        XCTAssertEqual(O.startVerdict(exited: nil, launching: true, elapsed: 1), .waiting)
        XCTAssertEqual(O.startVerdict(exited: nil, launching: false, elapsed: 1), .failed)
        XCTAssertEqual(O.startVerdict(exited: true, launching: false, elapsed: 2), .failed)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: 2), .waiting)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: O.startWindow), .started)
        XCTAssertEqual(O.failureMessage(kind: .codex, modelTitle: "GPT-6-Luna"), "Codex couldn't start with GPT-6-Luna. Choose another model.")
    }
}
