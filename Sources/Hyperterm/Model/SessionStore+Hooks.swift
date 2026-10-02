import AppKit

/// Turning agent hook events and statusLine reports into session state.
extension SessionStore {
    func handleHook(source: String, session: TerminalSession, payload: String, sentAt: UInt64?) {
        HookLog.append(source: source, sessionID: session.id.uuidString, payload: payload)
        // Hook processes race each other to the socket; an event stamped before the newest one
        // already applied is stale and must not roll state back.
        if let sentAt {
            guard sentAt >= session.lastHookSentAt else { return }
            session.lastHookSentAt = sentAt
        }
        session.lastHookAt = Date()
        let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
        switch source {
        case "claude":
            handleClaudeHook(session, json)
        case "codex-notify":
            session.recordAgentSessionId(json["thread-id"] as? String)
            if let last = json["last-assistant-message"] as? String {
                session.summary = summarize(last)
                session.record(.done, summarize(last) ?? "Turn complete")
            }
            session.apply(.codexTurnComplete, source: "codex notify")
            refreshReview(session)
        default:
            break
        }
    }

    private func handleClaudeHook(_ session: TerminalSession, _ json: [String: Any]) {
        let event = json["hook_event_name"] as? String ?? ""
        let cwd = json["cwd"] as? String
        // Only conversations with at least one prompt can be resumed.
        if ["UserPromptSubmit", "Stop", "PostToolUse"].contains(event) {
            session.recordAgentSessionId(json["session_id"] as? String)
        }
        // A tool call moving on means a prompt held open was answered in the terminal itself.
        if ["PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "UserPromptSubmit"].contains(event) {
            dropApproval(for: session)
        }

        switch event {
        case "UserPromptSubmit":
            if let prompt = json["prompt"] as? String {
                if prompt.hasPrefix("Message from @") {
                    session.record(.message, summarize(prompt) ?? prompt)
                } else {
                    session.summary = summarize(prompt).map { "› " + $0 }
                    session.record(.prompt, summarize(prompt, limit: 200) ?? prompt)
                }
            }
            session.readyForReview = false
            session.agentStatus = nil
        case "PreToolUse":
            if let tool = json["tool_name"] as? String {
                let input = json["tool_input"] as? [String: Any] ?? [:]
                let text = AgentText.describeTool(name: tool, input: input, cwd: cwd)
                session.activity = text
                session.pendingRequest = text
                let isEdit = ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
                if tool != "Read" && tool != "Glob" && tool != "Grep" { session.record(isEdit ? .edit : .tool, text) }
            }
        case "PostToolUse", "PostToolUseFailure":
            recordTestEvidence(session, json, failed: event == "PostToolUseFailure")
        case "Stop":
            session.activity = nil
            if let last = json["last_assistant_message"] as? String {
                session.summary = summarize(last)
                session.record(.done, summarize(last, limit: 200) ?? "Turn complete")
            }
            refreshReview(session)
        case "StopFailure":
            session.activity = nil
            let reason = failureReason(type: json["error"] as? String, details: json["error_details"] as? String)
            session.record(.failure, reason)
            session.apply(.claudeHook(event: event, notificationType: nil, message: reason), source: "claude hook")
            return
        case "SessionEnd":
            session.activity = nil
            // /clear and resume end one conversation but keep the agent running; the process
            // poll decides when the agent really exited.
            return
        case "TaskCreated":
            if let id = json["task_id"] as? String {
                session.tasks.subjects[id] = json["task_subject"] as? String ?? "Task"
                if !session.tasks.order.contains(id) { session.tasks.order.append(id) }
            }
            return
        case "TaskCompleted":
            if let id = json["task_id"] as? String { session.tasks.completed.insert(id) }
            return
        case "SubagentStart":
            session.record(.note, "Started subagent \(json["agent_type"] as? String ?? "")")
            return
        case "Notification":
            // With a PermissionRequest hook waiting, its request is the precise one.
            if session.hasHookApproval { return }
        default:
            break
        }

        let notificationType = json["notification_type"] as? String
        let message = json["message"] as? String
        let detail = notificationType == "permission_prompt" ? (session.pendingRequest ?? message) : message
        let keepRequest = session.pendingRequest
        session.apply(.claudeHook(event: event, notificationType: notificationType, message: detail), source: "claude hook")
        if session.state.needsAttention { session.pendingRequest = keepRequest }
    }

    private func recordTestEvidence(_ session: TerminalSession, _ json: [String: Any], failed: Bool) {
        guard json["tool_name"] as? String == "Bash",
              let command = (json["tool_input"] as? [String: Any])?["command"] as? String,
              TestCommand.matches(command) else { return }
        let response = json["tool_response"] as? [String: Any]
        let output = [response?["stdout"] as? String, response?["stderr"] as? String, json["error"] as? String]
            .compactMap { $0 }.joined(separator: "\n")
        let summary = TestCommand.summary(from: output, passed: !failed)
        session.testEvidence = TestEvidence(passed: !failed, summary: summary, date: Date())
        session.record(.test, (failed ? "Tests failing: " : "Tests passed: ") + summary)
    }

    /// StopFailure's error type, in words, with the reset time when it's a rate limit.
    private func failureReason(type: String?, details: String?) -> String {
        switch type {
        case "rate_limit":
            if let resets = rateLimits?.fiveHourResets ?? rateLimits?.sevenDayResets {
                return "Rate-limited · resets \(resets.formatted(date: .omitted, time: .shortened))"
            }
            return "Rate-limited"
        case "overloaded": return "API overloaded · try again shortly"
        case "billing_error": return "Billing error · check your plan"
        case "authentication_failed", "oauth_org_not_allowed": return "Authentication failed · run /login"
        case "max_output_tokens": return "Hit the output token limit"
        case "server_error": return "API server error"
        default: return summarize(details ?? type ?? "") ?? "Turn ended with an error"
        }
    }

    /// After a turn: recompute the diff and mark the agent ready for review when it changed files.
    func refreshReview(_ session: TerminalSession) {
        let path = session.spec.workPath
        let base = session.spec.baseBranch
        DispatchQueue.global(qos: .utility).async {
            let stat = Review.diffStat(at: path, base: base)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    session.diffStat = stat
                    if let stat, !stat.isEmpty, session.state == .idle { session.readyForReview = true }
                }
            }
        }
    }

    // MARK: - statusLine

    func handleStatusLine(session: TerminalSession, payload: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        var usage = session.usage
        usage.costUSD = (json["cost"] as? [String: Any])?["total_cost_usd"] as? Double
        usage.contextPercent = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double
        usage.model = (json["model"] as? [String: Any])?["display_name"] as? String
        if let limits = json["rate_limits"] as? [String: Any] {
            func window(_ key: String) -> (Double?, Date?) {
                let entry = limits[key] as? [String: Any]
                let reset = (entry?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return (entry?["used_percentage"] as? Double, reset)
            }
            let five = window("five_hour"), seven = window("seven_day")
            let parsed = RateLimits(fiveHourPercent: five.0, fiveHourResets: five.1, sevenDayPercent: seven.0, sevenDayResets: seven.1)
            usage.limits = parsed
            if rateLimits != parsed { rateLimits = parsed }
        }
        if session.usage != usage { session.usage = usage }
    }
}

/// Recent hook payloads in ~/.hyperterm/hooks.log, for diagnosing status detection. Capped.
enum HookLog {
    private static let url = ControlPaths.supportDirectory.appendingPathComponent("hooks.log")
    private static let queue = DispatchQueue(label: "dev.hyperterm.hooklog", qos: .background)

    static func append(source: String, sessionID: String?, payload: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(source) \(sessionID ?? "-") \(payload.replacingOccurrences(of: "\n", with: " ").prefix(2000))\n"
        queue.async {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
                return
            }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }
}
