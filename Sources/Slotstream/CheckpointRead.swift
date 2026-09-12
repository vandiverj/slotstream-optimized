import Foundation
import Darwin

/// Recoverable description at the syscall boundary. The inference caller still
/// fails closed on a genuine storage failure: partially filled tensor buffers
/// must never reach GPU evaluation or a successful response.
package enum CheckpointRead {
    package static func abort(file: String, error: Error) -> Never {
        // Optimized precondition traps may omit their message. Emit the actual
        // storage failure before terminating the now-untrustworthy process.
        FileHandle.standardError.write(Data("fatal checkpoint I/O (\(file)): \(error)\n".utf8))
        preconditionFailure("checkpoint storage failure")
    }

    package static func exactly(
        fd: Int32, into destination: UnsafeMutableRawPointer, offset: Int, count: Int,
        read: (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { Darwin.pread($0, $1, $2, $3) }
    ) throws {
        let (_, overflow) = offset.addingReportingOverflow(count)
        guard offset >= 0, count >= 0, !overflow else { throw ModelError("invalid checkpoint read range") }
        var done = 0
        while done < count {
            let got = read(fd, destination + done, count - done, off_t(offset + done))
            if got < 0 {
                let code = errno
                if code == EINTR { continue }
                throw ModelError("checkpoint read failed at byte \(offset + done): \(String(cString: strerror(code))) (errno \(code))")
            }
            guard got > 0 else {
                throw ModelError("checkpoint ended at byte \(offset + done); expected \(count - done) more bytes (file truncated or incomplete)")
            }
            guard got <= count - done else { throw ModelError("checkpoint read returned an invalid byte count") }
            done += got
        }
    }
}
