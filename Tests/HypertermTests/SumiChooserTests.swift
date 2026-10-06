import XCTest
@testable import Hyperterm

@MainActor
final class SumiChooserTests: XCTestCase {
    func testKeysMap() {
        XCTAssertEqual(SumiChooserKey.from(keyCode: 126, characters: nil), .up)
        XCTAssertEqual(SumiChooserKey.from(keyCode: 125, characters: nil), .down)
        XCTAssertEqual(SumiChooserKey.from(keyCode: 36, characters: "\r"), .confirm)
        XCTAssertEqual(SumiChooserKey.from(keyCode: 76, characters: nil), .confirm)
        XCTAssertEqual(SumiChooserKey.from(keyCode: 53, characters: nil), .back)
        XCTAssertEqual(SumiChooserKey.from(keyCode: 18, characters: "1"), .number(1))
        XCTAssertNil(SumiChooserKey.from(keyCode: 29, characters: "0"))
        XCTAssertNil(SumiChooserKey.from(keyCode: 0, characters: "a"))
    }

    func testArrowsMoveWithinBoundsAndSkipDisabledRows() {
        var model = SumiChooserModel()
        XCTAssertEqual(model.handle(.up, count: 3), .none)
        XCTAssertEqual(model.selection, 0)
        _ = model.handle(.down, count: 3, isEnabled: { $0 != 1 })
        XCTAssertEqual(model.selection, 2)
        _ = model.handle(.down, count: 3)
        XCTAssertEqual(model.selection, 2)
    }

    func testReturnPicksSelectionAndNumbersPickDirectly() {
        var model = SumiChooserModel(step: nil, selection: 1)
        XCTAssertEqual(model.handle(.confirm, count: 3), .pick(1))
        XCTAssertEqual(model.handle(.number(3), count: 3), .pick(2))
        XCTAssertEqual(model.selection, 2)
        XCTAssertEqual(model.handle(.number(4), count: 3), .none)
        XCTAssertEqual(model.handle(.number(1), count: 3, isEnabled: { $0 != 0 }), .none)
        XCTAssertEqual(model.handle(.back, count: 3), .back)
    }

    func testModelStepPreselectsTheRecommendedModel() {
        let model = SumiChooserModel.models(for: .codex)
        XCTAssertEqual(SessionStore.sumiModels(for: .codex)[model.selection].recommended, true)
    }

    func testFailedModelIsNotOfferedFirst() {
        let model = SumiChooserModel.models(for: .codex, notice: "x", avoiding: "gpt-6-luna")
        XCTAssertNotEqual(SessionStore.sumiModels(for: .codex)[model.selection].name, "gpt-6-luna")
        XCTAssertEqual(model.notice, "x")
    }

    func testSoleInstalledCLISkipsTheCLIStep() {
        XCTAssertEqual(SumiOnboarding.soleCLI(installed: [.codex]), .codex)
        XCTAssertNil(SumiOnboarding.soleCLI(installed: [.codex, .claude]))
        XCTAssertNil(SumiOnboarding.soleCLI(installed: []))
        XCTAssertNil(SumiOnboarding.soleCLI(installed: nil))
    }

    func testStartVerdicts() {
        typealias O = SumiOnboarding
        XCTAssertEqual(O.startVerdict(exited: nil, launching: true, elapsed: 1), .waiting)
        XCTAssertEqual(O.startVerdict(exited: nil, launching: false, elapsed: 1), .failed)
        XCTAssertEqual(O.startVerdict(exited: true, launching: false, elapsed: 2), .failed)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: 2), .waiting)
        XCTAssertEqual(O.startVerdict(exited: false, launching: false, elapsed: O.startWindow), .started)
        XCTAssertEqual(O.failureMessage(kind: .codex, modelTitle: "GPT-6-Luna"), "Codex couldn't start with GPT-6-Luna. Choose another model.")
    }
}
