import AppKit

/// PermissionRequest hooks held open until the user decides, answered through the CLI's own
/// decision API (no keystrokes). Prompts without a waiting hook fall back to pressing the
/// dialog's numbered option.
extension SessionStore {
    func registerApproval(for session: TerminalSession, source: String, payload: String, reply: @escaping ControlServer.Reply) {
        let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
        let tool = json["tool_name"] as? String ?? "tool"
        if session.isOrganizer, Self.organizerTools.contains(tool) {
            let approval = PendingApproval(source: source, toolName: tool, summary: tool, suggestions: nil, reply: reply)
            reply(ControlResponse.success(text: decisionJSON(approval, .approve, reason: nil)))
            return
        }
        let summary = AgentText.describeTool(name: tool, input: json["tool_input"] as? [String: Any] ?? [:], cwd: json["cwd"] as? String)
        dropApproval(for: session)
        let approval = PendingApproval(source: source, toolName: tool, summary: summary,
                                       suggestions: json["permission_suggestions"], reply: reply)
        approvals[session.id] = approval
        session.hasHookApproval = true
        // Plan mode ends by asking to exit it; the plan is the request.
        session.pendingPlan = tool == "ExitPlanMode" ? (json["tool_input"] as? [String: Any])?["plan"] as? String : nil
        session.pendingRequest = summary
        session.record(.approval, "Asked to run \(summary)")
        session.apply(.claudeHook(event: "Notification", notificationType: "permission_prompt", message: summary),
                      source: "permission hook", force: .needsInput(summary))
        notifier.postApproval(session: session, request: summary, alwaysRule: alwaysRuleText(approval))
        // Leave headroom under the hook's 600 s timeout so the CLI's own prompt takes over cleanly.
        let id = approval.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 540) { [weak self, weak session] in
            guard let self, let session, self.approvals[session.id]?.id == id else { return }
            self.dropApproval(for: session)
        }
    }

    /// Answers whatever `session` is waiting on: a held hook if there is one, else its dialog.
    func answer(_ session: TerminalSession, _ answer: PromptAnswer, reason: String? = nil) -> Result<String, TerminalSession.PromptError> {
        guard let approval = approvals.removeValue(forKey: session.id) else {
            return session.answerPromptByKeys(answer)
        }
        session.hasHookApproval = false
        session.pendingPlan = nil
        approval.reply(ControlResponse.success(text: decisionJSON(approval, answer, reason: reason)))
        session.record(.approval, answer == .deny ? "Denied \(approval.summary)" : answer == .always ? "Always allowed \(approval.summary)" : "Allowed \(approval.summary)")
        session.apply(.userSubmitted, source: "approval", force: .working)
        notifier.clearApproval(session: session)
        return .success(answer == .deny ? "denied" : "approved")
    }

    /// Releases a held hook with no decision, so the CLI's own prompt (or its outcome) stands.
    func dropApproval(for session: TerminalSession) {
        guard let approval = approvals.removeValue(forKey: session.id) else { return }
        session.hasHookApproval = false
        session.pendingPlan = nil
        approval.reply(ControlResponse.success())
        notifier.clearApproval(session: session)
    }

    func alwaysRuleText(for session: TerminalSession) -> String? {
        approvals[session.id].flatMap(alwaysRuleText)
    }

    private func alwaysRuleText(_ approval: PendingApproval) -> String? {
        guard let suggestions = approval.suggestions as? [[String: Any]] else { return nil }
        for suggestion in suggestions where suggestion["type"] as? String == "addRules" {
            if let rule = (suggestion["rules"] as? [[String: Any]])?.first, let tool = rule["toolName"] as? String {
                let content = rule["ruleContent"] as? String
                return content.map { "\(tool)(\($0))" } ?? tool
            }
        }
        return nil
    }

    private func decisionJSON(_ approval: PendingApproval, _ answer: PromptAnswer, reason: String?) -> String {
        var decision: [String: Any]
        switch answer {
        case .approve:
            decision = ["behavior": "allow"]
        case .always:
            decision = ["behavior": "allow"]
            // Claude persists the rule it suggested; Codex rejects permission updates.
            if approval.source == "claude", let suggestions = approval.suggestions as? [[String: Any]], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": reason.map(sanitizeMessage) ?? "The user denied this in Kuronami."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
