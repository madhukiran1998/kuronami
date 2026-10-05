import AppKit

/// Turning agent hook events and statusLine reports into session state.
extension SessionStore {
    /// Payloads can be large (PostToolUse carries whole tool output), so they're parsed on a
    /// serial background queue and applied on main in arrival order.
    private static let parseQueue = DispatchQueue(label: "dev.hyperterm.hook-parse", qos: .userInitiated)

    private func parseOffMain(_ payload: String, then apply: @escaping @MainActor ([String: Any]) -> Void) {
        Self.parseQueue.async {
            nonisolated(unsafe) let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
            DispatchQueue.main.async {
                MainActor.assumeIsolated { apply(json ?? [:]) }
            }
        }
    }

    func handleHook(source: String, session: TerminalSession, payload: String, sentAt: UInt64?) {
        HookLog.append(source: source, sessionID: session.id.uuidString, payload: payload)
        parseOffMain(payload) { [weak self, weak session] json in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            self.applyHook(source: source, session: session, json: json, sentAt: sentAt)
        }
    }

    private func applyHook(source: String, session: TerminalSession, json: [String: Any], sentAt: UInt64?) {
        // Hook processes race each other to the socket; an event stamped before the newest one
        // already applied is stale and must not roll state back.
        if let sentAt {
            guard sentAt >= session.lastHookSentAt else { return }
            session.lastHookSentAt = sentAt
        }
        session.lastHookAt = Date()
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
            checkpoint(session, phase: .end, prompt: "")
            refreshReview(session)
            refreshCodexUsage(session)
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
            checkpoint(session, phase: .start, prompt: json["prompt"] as? String ?? "Turn")
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
            checkpoint(session, phase: .end, prompt: "")
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
        parseOffMain(payload) { [weak self, weak session] json in
            guard let self, let session, !json.isEmpty else { return }
            self.applyStatusLine(session: session, json: json)
        }
    }

    private func applyStatusLine(session: TerminalSession, json: [String: Any]) {
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
            recordLimits(parsed, for: session)
        }
        if session.usage != usage { session.usage = usage }
    }

    private func recordLimits(_ limits: RateLimits, for session: TerminalSession) {
        let key = "\(session.kind.rawValue)/\(session.spec.account ?? AgentAccount.defaultID)"
        if accountLimits[key] != limits { accountLimits[key] = limits }
    }

    // MARK: - Codex usage

    /// Reads the turn's usage from the Codex session log, off the main thread.
    func refreshCodexUsage(_ session: TerminalSession) {
        guard session.kind == .codex, let thread = session.spec.agentSessionId else { return }
        let root = (AccountStore.shared.account(session.spec.account, kind: .codex)
            ?? AgentAccount(id: AgentAccount.defaultID, kind: .codex, name: "Default")).homeDirectory
        Self.parseQueue.async {
            let reading = CodexUsage.logFile(thread: thread, in: root)
                .flatMap { CodexUsage.tail(of: $0) }
                .flatMap { CodexUsage.latest(in: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self, weak session] in
                    guard let self, let session, let reading else { return }
                    self.applyCodexUsage(reading, to: session)
                }
            }
        }
    }

    private func applyCodexUsage(_ reading: CodexUsage.Reading, to session: TerminalSession) {
        var usage = session.usage
        usage.contextPercent = reading.contextPercent ?? usage.contextPercent
        if let limits = reading.limits {
            usage.limits = limits
            if codexRateLimits != limits { codexRateLimits = limits }
            recordLimits(limits, for: session)
            if reading.limitReached {
                let resets = [limits.fiveHourResets, limits.sevenDayResets].compactMap { $0 }.filter { $0 > Date() }.min()
                let text = "Rate-limited" + (resets.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                    + " · Move to Account to continue"
                session.summary = text
                session.record(.failure, text)
            }
        }
        if session.usage != usage { session.usage = usage }
    }
}

/// Recent hook payloads in ~/.hyperterm/hooks.log, for diagnosing status detection. Capped.
/// Hooks fire on every tool call, so all formatting and I/O happens on a background queue
/// with one long-lived file handle.
enum HookLog {
    private static let url = ControlPaths.supportDirectory.appendingPathComponent("hooks.log")
    private static let queue = DispatchQueue(label: "dev.hyperterm.hooklog", qos: .background)
    private static let maxBytes: UInt64 = 2_000_000
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func append(source: String, sessionID: String?, payload: String) {
        let date = Date()
        queue.async {
            let text = payload.prefix(2000).replacingOccurrences(of: "\n", with: " ")
            let line = "\(formatter.string(from: date)) \(source) \(sessionID ?? "-") \(text)\n"
            write(Data(line.utf8))
        }
    }

    /// Runs on `queue` only.
    private static func write(_ data: Data) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle, let end = try? handle.seekToEnd() else { return }
        if end > maxBytes {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: data)
    }
}
