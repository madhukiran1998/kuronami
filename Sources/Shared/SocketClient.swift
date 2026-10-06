import Foundation

enum SocketClientError: Error, CustomStringConvertible {
    case connectFailed(String)
    case writeFailed
    case emptyResponse
    case badResponse(String)

    var description: String {
        switch self {
        case .connectFailed(let path): return "Tako isn't running (no socket at \(path))"
        case .writeFailed: return "failed to write request to Tako"
        case .emptyResponse: return "Tako closed the connection without replying"
        case .badResponse(let raw): return "unreadable reply from Tako: \(raw.prefix(200))"
        }
    }
}

/// Blocking request/response over the control socket. Used by the CLI, hooks, and MCP bridge.
func sendControlRequest(_ request: ControlRequest, socketPath: String = ControlPaths.socketPath, timeout: Int? = nil) throws -> ControlResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketClientError.connectFailed(socketPath) }
    defer { close(fd) }
    if let timeout {
        var value = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw SocketClientError.connectFailed(socketPath)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw SocketClientError.connectFailed(socketPath) }

    var line = try JSONEncoder().encode(request)
    line.append(0x0A)
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
    guard written == line.count else { throw SocketClientError.writeFailed }

    let raw = readLine(fd: fd)
    guard !raw.isEmpty else { throw SocketClientError.emptyResponse }
    do {
        return try JSONDecoder().decode(ControlResponse.self, from: raw)
    } catch {
        throw SocketClientError.badResponse(String(decoding: raw, as: UTF8.self))
    }
}

/// Reads until newline or EOF.
func readLine(fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
            data.append(contentsOf: buffer[0..<newline])
            break
        }
        data.append(contentsOf: buffer[0..<n])
    }
    return data
}
