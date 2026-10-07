import Darwin
import Foundation

/// How long `ht heavy` waits for a slot before running anyway.
private let heavyMaxWaitSeconds = 15 * 60

/// `ht heavy -- <cmd…>`: waits for one of Tako's heavy-job slots, then execs the command in
/// place. The slot is leased to this pid, so it frees when the command exits. When Tako
/// isn't reachable the command runs right away: the queue is a courtesy, never a gate.
func runHeavy(_ args: [String]) -> Never {
    let command = args.first == "--" ? Array(args.dropFirst()) : args
    guard !command.isEmpty else { fail("usage: ht heavy -- <command…>") }
    var req = ControlRequest(cmd: .heavy)
    req.text = "acquire"
    req.pid = getpid()
    let notice = DispatchWorkItem {
        FileHandle.standardError.write(Data("ht: waiting for a heavy-job slot…\n".utf8))
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: notice)
    // Bounded: a queue that never moves (a stuck holder, a Tako that stopped answering) mustn't
    // hold the job forever, so after the wait it runs anyway.
    let response: ControlResponse?
    let asked = Date()
    do {
        response = try sendControlRequest(req, timeout: heavyMaxWaitSeconds)
    } catch SocketClientError.emptyResponse {
        // Also what Tako quitting mid-wait looks like; only a full wait is a timeout.
        let waited = Date().timeIntervalSince(asked) >= Double(heavyMaxWaitSeconds - 1)
        let why = waited ? "no heavy-job slot after \(heavyMaxWaitSeconds / 60) min" : "Tako stopped answering"
        FileHandle.standardError.write(Data("ht: \(why); running anyway\n".utf8))
        response = nil
    } catch {
        response = nil
    }
    notice.cancel()
    if let response, !response.ok {
        FileHandle.standardError.write(Data("ht: \(response.error ?? "no slot"); running anyway\n".utf8))
    }
    let argv = command.map { strdup($0) } + [nil]
    execvp(command[0], argv)
    fail("ht: \(command[0]): \(String(cString: strerror(errno)))", code: 127)
}
