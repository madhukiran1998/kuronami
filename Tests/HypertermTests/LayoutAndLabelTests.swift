import XCTest
@testable import Hyperterm

final class LayoutAndLabelTests: XCTestCase {
    func testLabelsNormalize() {
        XCTAssertEqual(normalizeLabel(" @API "), "api")
        XCTAssertEqual(normalizeLabel("web server"), "web-server")
        XCTAssertEqual(normalizeLabel("ui_v2.1"), "ui_v2.1")
    }

    func testGridShapePrefersSideBySideForTwo() {
        let shape = TerminalAreaView.gridShape(count: 2, aspect: 1.5)
        XCTAssertEqual(shape.columns, 2)
        XCTAssertEqual(shape.rows, 1)
    }

    func testGridShapeForFourIsTwoByTwo() {
        let shape = TerminalAreaView.gridShape(count: 4, aspect: 1.5)
        XCTAssertEqual(shape.columns, 2)
        XCTAssertEqual(shape.rows, 2)
    }

    func testGridFramesCoverEveryTileWithoutOverlap() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        for count in 1...9 {
            let frames = TerminalAreaView.frames(count: count, in: bounds, mode: .grid)
            XCTAssertEqual(frames.count, count)
            for (i, a) in frames.enumerated() {
                XCTAssertTrue(bounds.contains(a), "tile \(i) of \(count) escapes bounds")
                for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "tiles overlap for count \(count)") }
            }
        }
    }

    func testFocusFloatsInsetFromEdges() {
        let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
        XCTAssertEqual(TerminalAreaView.frames(count: 1, in: bounds, mode: .focus), [bounds.insetBy(dx: 10, dy: 10)])
    }

    func testFuzzyScore() {
        XCTAssertEqual(SwitcherModel.fuzzyScore("ap", "api"), 100)
        XCTAssertGreaterThan(SwitcherModel.fuzzyScore("ai", "api"), 0)
        XCTAssertEqual(SwitcherModel.fuzzyScore("zz", "api"), 0)
    }

    func testShortPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(shortPath(home + "/Code/app"), "~/Code/app")
        XCTAssertEqual(shortPath("/a/b/c/d/e"), "…/d/e")
    }
}
