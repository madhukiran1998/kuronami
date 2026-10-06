import Foundation

/// The pinned server. scripts/browser-mcp-tools.sh captures its handshake and tools into
/// BrowserMCPTools.swift; rerun it after changing this.
let chromeDevtoolsMCP = "chrome-devtools-mcp@1.10.1"

/// `ht browser-mcp`: an agent's browser tools. Proxies `chrome-devtools-mcp`, which is attached
/// to Kuronami's Chromium and sees every Kuronami browser, and scopes it to this agent:
///
/// - Nothing starts until the first tool call: the handshake and tool list are answered from
///   BrowserMCPTools.swift, then Chromium, this agent's browser session and chrome-devtools-mcp
///   start on that call. If the server exits, the next call starts it again.
/// - `pageId` defaults to the agent's own browser and stops being required, so agents never act
///   on another agent's page by accident; passing another browser's pageId is still allowed.
/// - `list_pages` names each page's Kuronami browser, so agents can find others by @label.
/// - `new_page`/`close_page` are refused: Kuronami browsers are sessions the user can see.
func runBrowserMCP(port: Int) -> Never {
    let proxy = BrowserProxy(port: port)
    proxy.run()
}

private final class BrowserProxy: @unchecked Sendable {
    /// Where chrome-devtools-mcp attaches; follows the browser if it had to take another port.
    private var browserURL: String
    /// The agent's handshake, replayed to each server that is started.
    private var handshake: [String] = []
    private var staticTools: [String: Any] = [:]
    private let outputLock = NSLock()
    private let stateLock = NSLock()
    /// Held while the browser and server are started, so concurrent first calls start one.
    private let startLock = NSLock()

    // Guarded by stateLock.
    private var child: Process?
    private var toChild: FileHandle?
    /// Agent requests the running server hasn't answered, by id key; failed if it exits.
    private var pending: [String: Any] = [:]
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
        browserURL = "http://127.0.0.1:\(port)"
    }

    func run() -> Never {
        // A server that died mid-write must not take the proxy with it.
        signal(SIGPIPE, SIG_IGN)
        let capture = (try? JSONSerialization.jsonObject(with: Data(browserMCPCapture.utf8))) as? [String: Any] ?? [:]
        staticTools = rewritten(["result": ["tools": capture["tools"] ?? []]], .toolsList)["result"] as? [String: Any] ?? [:]
        while let line = readLine(strippingNewline: false) {
            handleAgentLine(line, capture: capture)
        }
        let (process, input) = withState { (self.child, self.toChild) }
        try? input?.close()
        process?.waitUntilExit()
        exit(process?.terminationStatus ?? 0)
    }

    // MARK: - Server process

    private var serverRunning: Bool { withState { self.child != nil } }

    /// Starts chrome-devtools-mcp at `browserURL` and replays the agent's handshake to it.
    private func startServer() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // npx stays running as the server's parent (~80MB), so run a cached copy with node directly.
        let command = cachedServerScript().map { ["node", $0] } ?? ["npx", "-y", chromeDevtoolsMCP]
        process.arguments = command + ["--browser-url", browserURL,
                                       "--no-usage-statistics", "--no-performance-crux"]
        var environment = ProcessInfo.processInfo.environment
        environment["CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("ht: couldn't start chrome-devtools-mcp (\(command[0])): \(error)\n".utf8))
            return false
        }
        withState {
            self.child = process
            self.toChild = input.fileHandleForWriting
        }
        Thread.detachNewThread { [self] in relayChildOutput(from: output, of: process) }
        // Their replies are ours to swallow: the agent already got them. The first start may
        // include npx downloading the package.
        for line in handshake {
            guard var message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            guard message["id"] != nil else {
                sendToChild(line)
                continue
            }
            message["id"] = "ht-handshake"
            let semaphore = DispatchSemaphore(value: 0)
            withState { self.hiddenWaiters["ht-handshake"] = semaphore }
            let answered = sendToChild(message) && semaphore.wait(timeout: .now() + 120) == .success
            let reply = withState { () -> [String: Any]? in
                self.hiddenWaiters["ht-handshake"] = nil
                return self.hiddenReplies.removeValue(forKey: "ht-handshake")
            }
            guard answered, reply != nil else {
                stopServer(process)
                return false
            }
        }
        return withState { self.child === process }
    }

    /// The pinned server's entry script in npx's cache, if an earlier npx run downloaded it.
    private func cachedServerScript() -> String? {
        let name = "chrome-devtools-mcp"
        let version = chromeDevtoolsMCP.split(separator: "@").last.map(String.init)
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        let entries = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let package = entry.appendingPathComponent("node_modules/\(name)")
            guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  manifest["version"] as? String == version,
                  let bin = (manifest["bin"] as? [String: String])?[name] else { continue }
            let script = package.appendingPathComponent(bin).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: script) { return script }
        }
        return nil
    }

    private func stopServer(_ process: Process) {
        withState {
            guard self.child === process else { return }
            self.child = nil
            self.toChild = nil
        }
        process.terminate()
        childGone(process)
    }

    /// The server exited: fail what it was asked and let the next call start a new one.
    private func childGone(_ process: Process) {
        let (orphans, waiters) = withState { () -> ([Any], [DispatchSemaphore]) in
            if self.child === process {
                self.child = nil
                self.toChild = nil
            }
            guard self.child == nil else { return ([], []) }
            let orphans = Array(self.pending.values), waiters = Array(self.hiddenWaiters.values)
            for key in self.pending.keys { self.rewrites[key] = nil }
            self.pending = [:]
            self.hiddenWaiters = [:]
            return (orphans, waiters)
        }
        waiters.forEach { $0.signal() }
        for id in orphans {
            replyRPCError(id: id, "chrome-devtools-mcp exited before answering. Call the tool again to restart it.")
        }
    }

    // MARK: - Agent → server

    private func handleAgentLine(_ line: String, capture: [String: Any]) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let method = message["method"] as? String else {
            sendToChild(line)
            return
        }
        if ["initialize", "notifications/initialized", "logging/setLevel"].contains(method) { handshake.append(line) }
        guard let id = message["id"] else {
            sendToChild(line)
            return
        }
        switch method {
        case "initialize":
            var result = capture["initialize"] as? [String: Any] ?? [:]
            let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
            result["protocolVersion"] = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? supportedProtocolVersions[0]
            writeToAgent(rewritten(["jsonrpc": "2.0", "id": id, "result": result], .initialize))
        case "tools/list":
            writeToAgent(["jsonrpc": "2.0", "id": id, "result": staticTools])
        case "ping":
            writeToAgent(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        case "tools/call":
            handleToolCall(message, id: id)
        default:
            if serverRunning {
                forward(message, id: id)
            } else if method == "logging/setLevel" {
                writeToAgent(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            } else {
                replyRPCError(id: id, code: -32601, "Method not found: \(method)")
            }
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
        startLock.lock()
        guard let (own, fresh) = ensureBrowser(tool: tool) else {
            startLock.unlock()
            replyError(id: id, "Kuronami's browser isn't available right now. Ask the user to check the browser in Kuronami.")
            return
        }
        guard serverRunning || startServer() else {
            startLock.unlock()
            replyRPCError(id: id, "Couldn't start the browser tools (chrome-devtools-mcp via npx). Check that Node.js and npx are installed.")
            return
        }
        if fresh { refreshPageMap(alreadyMarked: true) }
        startLock.unlock()
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
        forward(message, id: id)
    }

    /// Sends an agent request to the server, failing it if there is no server to answer.
    private func forward(_ message: [String: Any], id: Any) {
        let key = "\(id)"
        let registered = withState { () -> Bool in
            guard self.child != nil else { return false }
            self.pending[key] = id
            return true
        }
        guard registered, sendToChild(message) else {
            let orphaned = withState { () -> Bool in
                self.rewrites[key] = nil
                return self.pending.removeValue(forKey: key) != nil || !registered
            }
            if orphaned { replyRPCError(id: id, "chrome-devtools-mcp isn't running. Call the tool again to restart it.") }
            return
        }
    }

    // MARK: - Kuronami

    /// Starts Chromium and this agent's browser when there is no server yet (blocking only that
    /// call), learning its endpoint; afterwards just reports the action for the
    /// "@agent · click" indicator. `fresh` means the page map has to be learned again.
    private func ensureBrowser(tool: String) -> (label: String, fresh: Bool)? {
        var req = ControlRequest(cmd: .browser)
        req.from = callerSession
        req.text = tool
        if let ownLabel = withState({ self.ownLabel }), serverRunning {
            DispatchQueue.global().async { _ = try? sendControlRequest(req, timeout: 2) }
            return (ownLabel, false)
        }
        guard let response = try? sendControlRequest(req, timeout: 30), response.ok, let label = response.text else {
            return nil
        }
        if let endpoint = response.endpoint { browserURL = endpoint }
        withState { self.ownLabel = label }
        return (label, true)
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
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        guard sendToChild(message), semaphore.wait(timeout: .now() + 15) == .success else {
            withState { self.hiddenWaiters[id] = nil }
            return nil
        }
        let reply = withState { self.hiddenReplies.removeValue(forKey: id) }
        return text(of: reply)
    }

    // MARK: - Server → agent

    private func relayChildOutput(from pipe: Pipe, of process: Process) {
        defer { childGone(process) }
        guard let stream = fdopen(pipe.fileHandleForReading.fileDescriptor, "r") else { return }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        while getline(&buffer, &capacity, stream) > 0, let buffer {
            let line = String(cString: buffer)
            handleServerLine(line)
        }
    }

    private func handleServerLine(_ line: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = message["id"] else {
            writeToAgent(line)
            return
        }
        let key = "\(id)"
        if message["method"] == nil { withState { self.pending[key] = nil } }
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

    private func replyRPCError(id: Any, code: Int = -32603, _ text: String) {
        writeToAgent(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
    }

    /// False when no server is running or it has gone away.
    @discardableResult
    private func sendToChild(_ line: String) -> Bool {
        guard let handle = withState({ self.toChild }) else { return false }
        return (try? handle.write(contentsOf: Data(line.utf8))) != nil
    }

    @discardableResult
    private func sendToChild(_ message: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return sendToChild(String(decoding: data, as: UTF8.self) + "\n")
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

/// What the MCP SDK in chrome-devtools-mcp@1.10.1 negotiates, newest first.
private let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]

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

/// evaluate_script replies with the value as JSON in a code block: `"charlie"` or `null`.
private func firstQuotedString(in text: String) -> String? {
    guard let start = text.firstIndex(of: "\"") else { return nil }
    let rest = text[text.index(after: start)...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[..<end])
    return value.isEmpty ? nil : value
}
