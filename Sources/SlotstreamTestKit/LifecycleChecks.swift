import Foundation
import Darwin
import Slotstream
import SlotstreamDiagnostics

extension Catalogue {
    static func serverLifecycle() throws -> CheckReport {
        var c = CheckBuilder("server-lifecycle")
        let state = ServerLifecycle()
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ServerError("socketpair failed") }
        defer { close(pair[1]) }
        c.expect("connection admitted before shutdown", state.register(pair[0]))
        state.beginShutdown()
        c.expect("shutdown visible", state.isStopping)
        c.expect("new connection refused", !state.register(pair[1]))
        c.expect("active connection delays drain", !state.wait(timeout: 0))
        var byte: UInt8 = 42
        c.equal("grace preserves the active socket", Darwin.write(pair[0], &byte, 1), 1)
        c.equal("grace delivers active bytes", Darwin.read(pair[1], &byte, 1), 1)
        state.cancelConnections()
        c.equal("cancellation wakes blocked readers", Darwin.read(pair[0], &byte, 1), 0)
        // Cancel does not close/recycle the worker-owned fd.
        c.expect("worker retains descriptor ownership", fcntl(pair[0], F_GETFD) >= 0)
        state.finish(pair[0])
        c.expect("worker completion closes descriptor", fcntl(pair[0], F_GETFD) == -1)
        state.finish(pair[0])
        c.expect("drain completes; duplicate finish is harmless", state.wait(timeout: 0))
        state.cancelConnections()
        let watchdog = ServerLifecycle()
        c.expect("idle server never expires", !watchdog.stalled(timeout: 10, now: 100))
        watchdog.beginInference(now: 0)
        c.expect("active work gets its progress window", !watchdog.stalled(timeout: 10, now: 9))
        watchdog.beginInference(now: 9)
        c.expect("queued work cannot renew a stalled generation", watchdog.stalled(timeout: 10, now: 10))
        watchdog.progress(now: 10)
        c.expect("real progress renews deadline", !watchdog.stalled(timeout: 10, now: 19))
        watchdog.endInference()
        c.expect("remaining work stays monitored", watchdog.stalled(timeout: 10, now: 20))
        watchdog.endInference()
        c.expect("completed work leaves no stale deadline", !watchdog.stalled(timeout: 10, now: 100))
        watchdog.beginInference(now: 100)
        watchdog.beginShutdown()
        c.expect("shutdown uses its own cleanup deadline", !watchdog.stalled(timeout: 10, now: 200))
        return c.report()
    }

    static func checkpointRead() throws -> CheckReport {
        var c = CheckBuilder("checkpoint-read")
        let destination = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { destination.deallocate() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ServerError("test file creation failed") }
        defer { close(fd); unlink(file.path) }
        let bytes: [UInt8] = [1, 2, 3, 4]
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == 4 else { throw ServerError("test file write failed") }
        try CheckpointRead.exactly(fd: fd, into: destination, offset: 0, count: 4)
        c.equal("real file read preserves bytes", Array(UnsafeBufferPointer(start: destination.assumingMemoryBound(to: UInt8.self), count: 4)), bytes)
        guard ftruncate(fd, 2) == 0 else { throw ServerError("test truncation failed") }
        do {
            try CheckpointRead.exactly(fd: fd, into: destination, offset: 0, count: 4)
            c.expect("real truncation rejected", false)
        } catch { c.expect("real truncation reports exact EOF", String(describing: error).contains("byte 2")) }
        c.expect("failed read leaves caller-owned descriptor open", fcntl(fd, F_GETFD) >= 0)
        var calls = 0
        try CheckpointRead.exactly(fd: -1, into: destination, offset: 7, count: 4) { _, pointer, count, offset in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            c.equal("partial read advances file offset", Int(offset), 7 + (calls - 2) * 2)
            c.equal("partial read advances destination", Int(bitPattern: pointer) - Int(bitPattern: destination), (calls - 2) * 2)
            c.equal("partial read reduces remaining count", count, 4 - (calls - 2) * 2)
            pointer.storeBytes(of: UInt16(0x1234), as: UInt16.self)
            return 2
        }
        c.equal("EINTR retried and partial reads joined", calls, 3)
        for (name, result, code, marker) in [("truncation", 0, Int32(0), "truncated"), ("I/O failure", -1, EIO, "errno") ] {
            do {
                try CheckpointRead.exactly(fd: -1, into: destination, offset: 7, count: 4) { _, _, _, _ in errno = code; return result }
                c.expect("\(name) fails", false)
            } catch { c.expect("\(name) explains failure", String(describing: error).contains(marker)) }
        }
        do {
            try CheckpointRead.exactly(fd: -1, into: destination, offset: Int.max, count: 1)
            c.expect("overflow refused", false)
        } catch { c.expect("overflow refused", true) }
        return c.report()
    }
}
