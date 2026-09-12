import Darwin
import Foundation
import Slotstream
import SlotstreamDiagnostics

extension Catalogue {
    /// Exercise the real bounded reader without allocating an Engine or weights.
    static func httpSocketReads() throws -> CheckReport {
        var c = CheckBuilder("http-socket-reads")
        func read(_ bytes: Data, timeout: TimeInterval = 1, fragmentSize: Int = 65_536,
                  interval: TimeInterval = 0, holdOpen: TimeInterval = 0) throws -> Server.ReadOutcome {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw ServerError("socketpair failed")
            }
            let reader = pair[0], writer = pair[1]
            let finished = DispatchGroup()
            defer {
                shutdown(reader, SHUT_RDWR)
                finished.wait()
                close(reader)
                close(writer)
            }
            var socketTimeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(reader, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            finished.enter()
            DispatchQueue.global().async {
                defer { shutdown(writer, SHUT_WR); finished.leave() }
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(writer, raw.baseAddress! + offset, min(fragmentSize, raw.count - offset))
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { break }
                        offset += n
                        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
                    }
                }
                if holdOpen > 0 { Thread.sleep(forTimeInterval: holdOpen) }
            }
            return Server.readRequest(reader, timeout: timeout)
        }
        for _ in 0..<16 {
            if case .closed = try read(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc".utf8)) {
                c.expect("interrupted body returns closed", true)
            } else { c.expect("interrupted body returns closed", false) }
        }
        let valid = Data("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcEXTRA".utf8)
        if case .ok(let request) = try read(valid) {
            c.equal("only the declared body is consumed", request.body, Data("abc".utf8))
        } else { c.expect("valid socket request parses", false) }
        let headerPrefix = "GET / HTTP/1.1\r\nPadding: "
        let exactHeader = headerPrefix + String(repeating: "x", count: 65_536 - headerPrefix.utf8.count)
        if case .ok = try read(Data((exactHeader + "\r\n\r\n").utf8)) {
            c.expect("socket header at the limit is accepted", true)
        } else { c.expect("socket header at the limit is accepted", false) }
        let oversized = Data(("GET / HTTP/1.1\r\nPadding: " + String(repeating: "x", count: 65_536) + "\r\n\r\n").utf8)
        if case .fail(let status, _) = try read(oversized) {
            c.equal("oversized terminated socket header", status, "431 Request Header Fields Too Large")
        } else { c.expect("oversized socket header rejected", false) }
        if case .fail(let status, _) = try read(Data([0xff]) + Data("\r\n\r\n".utf8)) {
            c.equal("invalid UTF-8 header", status, "400 Bad Request")
        } else { c.expect("invalid UTF-8 rejected", false) }
        for (name, bytes, fragment, interval, hold) in [
            ("idle client", Data(), 65_536, 0.0, 0.10),
            ("slow-drip header", Data("GET / HTTP/1.1\r\nPadding: unfinished".utf8), 1, 0.005, 0.0),
            ("stalled body", Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8), 65_536, 0.0, 0.10),
        ] {
            if case .fail(let status, _) = try read(bytes, timeout: 0.04, fragmentSize: fragment,
                                                   interval: interval, holdOpen: hold) {
                c.equal("\(name) has a finite upload deadline", status, "408 Request Timeout")
            } else { c.expect("\(name) times out", false) }
        }
        // Failure in a previous reader must not poison subsequent connections.
        if case .ok = try read(valid) { c.expect("reader recovers after timeouts", true) }
        else { c.expect("reader recovers after timeouts", false) }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ServerError("socketpair failed") }
        defer { close(pair[0]); if pair[1] >= 0 { close(pair[1]) } }
        guard Server.prepareConnection(pair[0]) else { throw ServerError("socket preparation failed") }
        c.expect("accepted socket is explicitly nonblocking", fcntl(pair[0], F_GETFL, 0) & O_NONBLOCK != 0)
        let reply = Data("small response".utf8)
        c.expect("ordinary response writes successfully", Server.writeResponse(pair[0], reply, timeout: 1))
        var received = [UInt8](repeating: 0, count: reply.count)
        let count = Darwin.read(pair[1], &received, received.count)
        c.equal("response bytes preserved", Data(received.prefix(max(0, count))), reply)
        var smallBuffer: Int32 = 4096
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
        c.expect("non-reading client cannot hold the writer indefinitely",
                 !Server.writeResponse(pair[0], Data(repeating: 42, count: 1 << 20), timeout: 0.04))
        close(pair[1]); pair[1] = -1
        c.expect("closed client fails the write without SIGPIPE",
                 !Server.writeResponse(pair[0], reply, timeout: 1))
        return c.report()
    }
}
