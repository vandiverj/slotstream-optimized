import Foundation
import MLX
import Slotstream
import SlotstreamDiagnostics

private enum StagingFinalizers {
    static let lock = NSLock()
    static var count = 0
    static func released(_ pointer: UnsafeMutableRawPointer?) {
        free(pointer)
        lock.lock()
        count += 1
        lock.unlock()
    }
    static func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

extension Catalogue {
    static func stagingOwnership() throws -> CheckReport {
        var c = CheckBuilder("staging-ownership")
        let before = StagingFinalizers.snapshot()
        for _ in 0..<128 {
            try autoreleasepool {
                var pointer: UnsafeMutableRawPointer?
                guard posix_memalign(&pointer, 16384, 16384) == 0, let pointer else {
                    throw ServerError("test staging allocation failed")
                }
                let words = pointer.bindMemory(to: UInt32.self, capacity: 4)
                let values: [UInt32] = [17, 23, 31, 47]
                for (i, value) in values.enumerated() { words[i] = value }
                var array: MLXArray? = adoptStagingBuffer(pointer, shape: [4], dtype: .uint32,
                                                        finalizer: { StagingFinalizers.released($0) })
                // Derived lazy work must retain the source through evaluation.
                let output = array! + UInt32(1)
                array = nil
                eval(output)
                c.equal("staged values survive lazy evaluation", output.asArray(UInt32.self), [18, 24, 32, 48])
                Stream.gpu.synchronize()
            }
        }
        Stream.gpu.synchronize()
        c.equal("each transferred buffer is finalized exactly once", StagingFinalizers.snapshot() - before, 128)
        return c.report()
    }
}
