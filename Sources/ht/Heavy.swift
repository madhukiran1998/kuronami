import Darwin
import Foundation

/// `ht heavy -- <cmd…>`: waits for one of Kuronami's heavy-job slots, then execs the command in
/// place. The slot is leased to this pid, so it frees when the command exits. When Kuronami
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
    let response = try? sendControlRequest(req)
    notice.cancel()
    if let response, !response.ok {
        FileHandle.standardError.write(Data("ht: \(response.error ?? "no slot"); running anyway\n".utf8))
    }
    let argv = command.map { strdup($0) } + [nil]
    execvp(command[0], argv)
    fail("ht: \(command[0]): \(String(cString: strerror(errno)))", code: 127)
}
