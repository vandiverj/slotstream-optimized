// HTTP framing and bounded socket reads. The caller owns and closes the fd.
// Kept separate from model routing so malformed input can be tested without weights.
import Darwin
import Foundation

extension Server {
    /// MSG_DONTWAIT alone did not bound AF_UNIX sends in a regression on
    /// Darwin. Set descriptor mode explicitly once, before any reads/writes.
    package static func prepareConnection(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                         socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static let generationPaths: Set<String> = [
        "/api/chat", "/api/generate", "/v1/chat/completions",
        "/v3/ai/language-model", "/v1/ai/language-model",
    ]

    package static func requiresGenerationAdmission(method: String, path: String) -> Bool {
        method == "POST" && generationPaths.contains(routePath(path))
    }

    package struct Request {
        package init() {}
        package var method = ""
        package var path = ""
        package var body = Data()
        package var headers: [String: String] = [:]
    }

    /// Largest request body accepted. Text prompts are tiny, but vision inputs
    /// (base64-encoded images) commonly reach several MB and must be served.
    /// The cap still exists to keep the read bounded against an unbounded
    /// attacker; requests past it get a 413 instead of a dropped connection.
    package static let maxBodyBytes = 32 << 20

    /// Why a request could not be read. `.closed` means the peer went away or
    /// closed the socket; everything else gets a real
    /// status line, because dropping the connection reads as a crash.
    package enum ReadOutcome {
        case ok(Request)
        case closed
        case fail(status: String, message: String)
    }

    /// An absolute monotonic deadline prevents a byte every few seconds from
    /// retaining a worker forever. The existing 30-second upload allowance is
    /// now for the complete head and body, not renewed by every successful read.
    package static func readRequest(_ fd: Int32, timeout: TimeInterval = 30) -> ReadOutcome {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func receive(_ buffer: inout [UInt8], count: Int) -> Int {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { errno = ETIMEDOUT; return -1 }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1000)))
                let ready = poll(&descriptor, 1, milliseconds)
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 { errno = ETIMEDOUT; return -1 }
                if ready < 0 { return -1 }
                let n = read(fd, &buffer, count)
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                return n
            }
        }
        func readFailure() -> ReadOutcome {
            if errno == ETIMEDOUT || errno == EAGAIN || errno == EWOULDBLOCK {
                return .fail(status: "408 Request Timeout", message: "request upload timed out")
            }
            return .closed
        }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>? = nil
        while headerEnd == nil {
            let n = receive(&tmp, count: tmp.count)
            if n < 0 { return readFailure() }
            if n == 0 { return .closed }
            buf.append(contentsOf: tmp[0 ..< n])
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, buf.count > (64 << 10) + 3 {
                return .fail(
                    status: "431 Request Header Fields Too Large",
                    message: "request headers are larger than 64 KiB")
            }
        }
        let headData = buf[..<headerEnd!.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            return .fail(status: "400 Bad Request", message: "request headers are not UTF-8")
        }
        let req: Request
        let contentLength: Int
        switch Self.parseHead(head) {
        case let .fail(status, message): return .fail(status: status, message: message)
        case let .ok(parsed, length):
            req = parsed
            contentLength = length
        }
        var body = Data(buf[headerEnd!.upperBound...].prefix(contentLength))
        while body.count < contentLength {
            let n = receive(&tmp, count: min(tmp.count, contentLength - body.count))
            if n < 0 { return readFailure() }
            if n == 0 { break }
            body.append(contentsOf: tmp[0 ..< n])
        }
        guard body.count == contentLength else { return .closed }
        var complete = req
        complete.body = body
        return .ok(complete)
    }

    /// Accepted sockets are nonblocking with SO_NOSIGPIPE set by run(). Send without blocking
    /// first, and poll only under backpressure. A slow reader cannot renew the
    /// 120-second allowance by accepting a few bytes on every write.
    package static func writeResponse(_ fd: Int32, _ data: Data, timeout: TimeInterval = 120) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return false }
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, MSG_DONTWAIT)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1000)))
                let ready = poll(&descriptor, 1, milliseconds)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { return false }
            }
            return true
        }
    }

    /// What the head said, or why the request cannot be served. Split out of
    /// the socket read so every framing rule below is reachable from a test
    /// with a string instead of a live server and a real client.
    package enum HeadOutcome {
        case ok(Request, contentLength: Int)
        case fail(status: String, message: String)
    }

    package static func parseHead(_ head: String) -> HeadOutcome {
        guard head.utf8.count <= 64 << 10 else {
            return .fail(status: "431 Request Header Fields Too Large",
                         message: "request headers are larger than 64 KiB")
        }
        var req = Request()
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .fail(status: "400 Bad Request", message: "malformed HTTP request line")
        }
        req.method = String(parts[0])
        req.path = String(parts[1])
        var contentLength = 0
        var sawContentLength = false
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let tokenChars = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            guard kv.count == 2, !kv[0].isEmpty,
                kv[0].allSatisfy({ tokenChars.contains($0) }),
                kv[1].utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else {
                return .fail(status: "400 Bad Request", message: "malformed HTTP header")
            }
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                req.headers[key] = value
                if key == "content-length" {
                    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                        let length = Int(value), !sawContentLength || length == contentLength else {
                        return .fail(status: "400 Bad Request", message: "invalid or conflicting Content-Length")
                    }
                    sawContentLength = true
                    contentLength = length
                }
            }
        }
        // A chunked body carries no Content-Length, so it used to be read as
        // zero bytes and failed further in as "messages must be an array".
        if req.headers["transfer-encoding"] != nil {
            return .fail(
                status: "411 Length Required",
                message: "chunked request bodies are not supported; send Content-Length")
        }
        if contentLength > maxBodyBytes {
            return .fail(
                status: "413 Content Too Large",
                message: "request body is larger than \(maxBodyBytes >> 20) MiB")
        }
        return .ok(req, contentLength: contentLength)
    }

    /// The path a request routes on: no query string, and no scheme or
    /// authority from the absolute-form target proxies send. Both are legal
    /// HTTP and both used to 404.
    package static func routePath(_ raw: String) -> String {
        var p = raw
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        for scheme in ["http://", "https://"] where p.lowercased().hasPrefix(scheme) {
            let afterScheme = p.index(p.startIndex, offsetBy: scheme.count)
            if let slash = p[afterScheme...].firstIndex(of: "/") {
                p = String(p[slash...])
            } else {
                p = "/"
            }
        }
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

}
