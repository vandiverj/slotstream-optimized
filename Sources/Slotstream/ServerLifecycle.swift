import Foundation
import Darwin

/// Owns accepted descriptors until their worker completes. Shutdown never closes
/// another thread's fd: it shuts sockets down under the same lock used to remove
/// and close them, preventing descriptor-number reuse races.
package final class ServerLifecycle {
    package init() {}
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var descriptors: Set<Int32> = []
    private var stopping = false
    private var inferenceCount = 0
    private var lastProgress: TimeInterval?

    package func beginInference(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        // A queued request must not renew a stuck active request's deadline.
        if inferenceCount == 0 { lastProgress = now }
        inferenceCount += 1
    }

    package func endInference() {
        lock.lock(); defer { lock.unlock() }
        inferenceCount -= 1
        if inferenceCount == 0 { lastProgress = nil }
    }

    package func progress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if inferenceCount > 0 { lastProgress = now }
    }

    package func stalled(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopping, inferenceCount > 0, let lastProgress, timeout > 0 else { return false }
        return now - lastProgress >= timeout
    }

    package var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    package func register(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopping else { return false }
        descriptors.insert(fd)
        workers.enter()
        return true
    }

    package func finish(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard descriptors.remove(fd) != nil else { return }
        close(fd)
        workers.leave()
    }

    package func beginShutdown() {
        lock.lock(); defer { lock.unlock() }
        stopping = true
    }

    package func cancelConnections() {
        lock.lock(); defer { lock.unlock() }
        stopping = true
        for fd in descriptors { _ = shutdown(fd, SHUT_RDWR) }
    }

    package func wait(timeout: TimeInterval) -> Bool {
        workers.wait(timeout: .now() + timeout) == .success
    }
}

package struct ServerStopped: Error {}
package struct ServerDrainTimedOut: Error {}
