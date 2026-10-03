import Foundation

/// `ht browser-mcp`: an agent's browser tools. Proxies `chrome-devtools-mcp`, which is attached
/// to Kuronami's Chromium and sees every Kuronami browser, and scopes it to this agent:
///
/// - Chromium (and this agent's browser session, @<agent>-web) starts on the first tool call.
/// - `pageId` defaults to the agent's own browser and stops being required, so agents never act
///   on another agent's page by accident; passing another browser's pageId is still allowed.
/// - `list_pages` names each page's Kuronami browser, so agents can find others by @label.
/// - `new_page`/`close_page` are refused: Kuronami browsers are sessions the user can see.
func runBrowserMCP(port: Int) -> Never {
    let proxy = BrowserProxy(port: port)
    proxy.run()
}

private final class BrowserProxy: @unchecked Sendable {
    private let child = Process()
    private let toChild = Pipe()
    private let fromChild = Pipe()
    private let outputLock = NSLock()
    private let stateLock = NSLock()

    // Guarded by stateLock.
    private var hiddenReplies: [String: [String: Any]] = [:]
    private var hiddenWaiters: [String: DispatchSemaphore] = [:]
    private var rewrites: [String: Rewrite] = [:]
    private var labelsByPage: [Int: String] = [:]
    private var ownLabel: String?
    private var pageScopedTools: Set<String> = []

    private var hiddenCounter = 0
    private var mapRefreshedAt = Date.distantPast

    private enum Rewrite { case initialize, toolsList, listPages }

    init(port: Int) {
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["npx", "-y", "chrome-devtools-mcp@1.10.1",
                           "--browser-url", "http://127.0.0.1:\(port)",
                           "--no-usage-statistics", "--no-performance-crux"]
        var environment = ProcessInfo.processInfo.environment
        environment["CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS"] = "1"
        child.environment = environment
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.standardError
    }

    func run() -> Never {
        child.terminationHandler = { exit($0.terminationStatus) }
        do { try child.run() } catch { fail("ht: couldn't start chrome-devtools-mcp via npx: \(error)") }
        Thread.detachNewThread { [self] in relayChildOutput() }
        while let line = readLine(strippingNewline: false) {
            handleAgentLine(line)
        }
        try? toChild.fileHandleForWriting.close()
        child.waitUntilExit()
        exit(child.terminationStatus)
    }

    // MARK: - Agent → server

    private func handleAgentLine(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String, let id = message["id"] else {
            sendToChild(line)
            return
        }
        switch method {
        case "initialize":
            track(id, .initialize)
            sendToChild(line)
        case "tools/list":
            track(id, .toolsList)
            sendToChild(line)
        case "tools/call":
            handleToolCall(message, id: id)
        default:
            sendToChild(line)
        }
    }

    private func handleToolCall(_ message: [String: Any], id: Any) {
        var message = message
        var params = message["params"] as? [String: Any] ?? [:]
        let tool = params["name"] as? String ?? ""
        if tool == "new_page" || tool == "close_page" {
            replyError(id: id, "Kuronami browsers are sessions the user can see, so pages aren't opened or closed from here. Navigate your own browser with navigate_page; ask the user to open another browser (⇧⌘B) if you need two.")
            return
        }
        guard let own = ensureBrowser(tool: tool) else {
            replyError(id: id, "Kuronami's browser isn't available right now. Ask the user to check the browser in Kuronami.")
            return
        }
        if tool == "list_pages" {
            refreshPageMap()
            track(id, .listPages)
        } else if pageScoped(tool) {
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            if staleMap() || ownPage(own) == nil { refreshPageMap() }
            let requested = arguments["pageId"] as? Int
            // Explicitly naming another Kuronami browser is allowed; anything else means "mine".
            if requested == nil || label(ofPage: requested!) == nil, let page = ownPage(own) {
                arguments["pageId"] = page
            }
            params["arguments"] = arguments
            message["params"] = params
        }
        sendToChild(message)
    }

    // MARK: - Kuronami

    /// Starts Chromium and this agent's browser on the first call (blocking only that call);
    /// afterwards just reports the action for the "@agent · click" indicator.
    private func ensureBrowser(tool: String) -> String? {
        if let ownLabel = withState({ self.ownLabel }) {
            var req = ControlRequest(cmd: .browser)
            req.from = callerSession
            req.text = tool
            DispatchQueue.global().async { _ = try? sendControlRequest(req, timeout: 2) }
            return ownLabel
        }
        var req = ControlRequest(cmd: .browser)
        req.from = callerSession
        req.text = tool
        guard let response = try? sendControlRequest(req, timeout: 30), response.ok, let label = response.text else {
            return nil
        }
        withState { self.ownLabel = label }
        refreshPageMap(alreadyMarked: true)
        return label
    }

    /// Learns which chrome-devtools-mcp page number is which Kuronami browser: Kuronami tags
    /// each page with its label, and each page is asked for its tag.
    private func refreshPageMap(alreadyMarked: Bool = false) {
        if !alreadyMarked {
            var req = ControlRequest(cmd: .browser)
            req.from = callerSession
            req.text = "mark"
            _ = try? sendControlRequest(req, timeout: 5)
        }
        guard let listing = hiddenCall("list_pages", [:]) else { return }
        var map: [Int: String] = [:]
        for page in pageNumbers(in: listing) {
            let reply = hiddenCall("evaluate_script", ["pageId": page, "function": "() => window.__hyperterm ?? null"])
            if let reply, let tag = firstQuotedString(in: reply) { map[page] = tag }
        }
        withState {
            self.labelsByPage = map
            self.mapRefreshedAt = Date()
        }
    }

    private func staleMap() -> Bool { withState { Date().timeIntervalSince(self.mapRefreshedAt) > 15 } }
    private func ownPage(_ label: String) -> Int? { withState { self.labelsByPage.first { $0.value == label }?.key } }
    private func label(ofPage page: Int) -> String? { withState { self.labelsByPage[page] } }
    private func pageScoped(_ tool: String) -> Bool { withState { self.pageScopedTools.contains(tool) } }

    // MARK: - Hidden calls

    /// A tool call of our own; its reply is consumed here, never shown to the agent.
    private func hiddenCall(_ tool: String, _ arguments: [String: Any]) -> String? {
        let id = withState { () -> String in
            self.hiddenCounter += 1
            return "ht-\(self.hiddenCounter)"
        }
        let semaphore = DispatchSemaphore(value: 0)
        withState { self.hiddenWaiters[id] = semaphore }
        sendToChild(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            withState { self.hiddenWaiters[id] = nil }
            return nil
        }
        let reply = withState { self.hiddenReplies.removeValue(forKey: id) }
        return text(of: reply)
    }

    // MARK: - Server → agent

    private func relayChildOutput() {
        guard let stream = fdopen(fromChild.fileHandleForReading.fileDescriptor, "r") else { return }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        while getline(&buffer, &capacity, stream) > 0, let buffer {
            let line = String(cString: buffer)
            handleServerLine(line)
        }
    }

    private func handleServerLine(_ line: String) {
        let interesting = withState { !self.hiddenWaiters.isEmpty || !self.rewrites.isEmpty }
        guard interesting, let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = message["id"] else {
            writeToAgent(line)
            return
        }
        let key = "\(id)"
        if let waiter = withState({ self.hiddenWaiters.removeValue(forKey: key) }) {
            withState { self.hiddenReplies[key] = message }
            waiter.signal()
            return
        }
        guard let rewrite = withState({ self.rewrites.removeValue(forKey: key) }) else {
            writeToAgent(line)
            return
        }
        writeToAgent(rewritten(message, rewrite))
    }

    private func rewritten(_ message: [String: Any], _ rewrite: Rewrite) -> [String: Any] {
        var message = message
        guard var result = message["result"] as? [String: Any] else { return message }
        switch rewrite {
        case .initialize:
            let note = "Each Kuronami agent has its own browser, shown to the user as a session. Tools act on yours by default, so leave out pageId. list_pages names every Kuronami browser by @label; pass another browser's pageId only when you mean to use it."
            let existing = result["instructions"] as? String
            result["instructions"] = existing.map { note + "\n\n" + $0 } ?? note
        case .toolsList:
            var tools = result["tools"] as? [[String: Any]] ?? []
            var scoped: Set<String> = []
            for index in tools.indices {
                guard var schema = tools[index]["inputSchema"] as? [String: Any],
                      var properties = schema["properties"] as? [String: Any], properties["pageId"] != nil else { continue }
                scoped.insert(tools[index]["name"] as? String ?? "")
                schema["required"] = (schema["required"] as? [String] ?? []).filter { $0 != "pageId" }
                if var pageId = properties["pageId"] as? [String: Any] {
                    pageId["description"] = "Optional. Defaults to your own Kuronami browser; pass another page's id (see list_pages) to use that browser."
                    properties["pageId"] = pageId
                }
                schema["properties"] = properties
                tools[index]["inputSchema"] = schema
            }
            tools.removeAll { ["new_page", "close_page"].contains($0["name"] as? String ?? "") }
            withState { self.pageScopedTools = scoped }
            result["tools"] = tools
        case .listPages:
            let own = withState { self.ownLabel }
            let labels = withState { self.labelsByPage }
            if var content = result["content"] as? [[String: Any]] {
                for index in content.indices {
                    guard let text = content[index]["text"] as? String else { continue }
                    content[index]["text"] = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                        guard let page = pageNumber(in: line), let label = labels[page] else { return String(line) }
                        return line + "  — @\(label)" + (label == own ? " (your browser)" : "")
                    }.joined(separator: "\n")
                }
                result["content"] = content
            }
        }
        message["result"] = result
        return message
    }

    // MARK: - Plumbing

    private func track(_ id: Any, _ rewrite: Rewrite) { withState { self.rewrites["\(id)"] = rewrite } }

    private func replyError(id: Any, _ text: String) {
        writeToAgent(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
    }

    private func sendToChild(_ line: String) {
        toChild.fileHandleForWriting.write(Data(line.utf8))
    }

    private func sendToChild(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        toChild.fileHandleForWriting.write(data + Data("\n".utf8))
    }

    private func writeToAgent(_ line: String) {
        outputLock.lock()
        FileHandle.standardOutput.write(Data(line.utf8))
        outputLock.unlock()
    }

    private func writeToAgent(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        writeToAgent(String(decoding: data, as: UTF8.self) + "\n")
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

// MARK: - Parsing chrome-devtools-mcp's text output

private func text(of message: [String: Any]?) -> String? {
    let content = (message?["result"] as? [String: Any])?["content"] as? [[String: Any]]
    return content?.compactMap { $0["text"] as? String }.joined(separator: "\n")
}

/// Lines like "2: Example Domain (https://example.com/) [selected]".
private func pageNumber(in line: Substring) -> Int? {
    let trimmed = line.drop { $0 == " " }
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    return Int(trimmed[..<colon])
}

private func pageNumbers(in listing: String) -> [Int] {
    listing.split(separator: "\n").compactMap(pageNumber(in:))
}

/// evaluate_script replies with the value as JSON in a code block: `"api-web"` or `null`.
private func firstQuotedString(in text: String) -> String? {
    guard let start = text.firstIndex(of: "\"") else { return nil }
    let rest = text[text.index(after: start)...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[..<end])
    return value.isEmpty ? nil : value
}
