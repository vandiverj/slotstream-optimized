import Foundation
import Slotstream
import SlotstreamDiagnostics

extension Catalogue {
    static func routerTrace() throws -> CheckReport {
        var c = CheckBuilder("router-trace")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("trace")
        let recorder = RouterTraceRecorder(limit: 16)
        recorder.record(layer: 1, tokens: 1, topK: 2, ids: [3, 4])
        c.expect("valid trace reports success", recorder.flush(to: file)?.hasPrefix("router trace:") == true)
        let expected = Data([1,0,0,0, 1,0,0,0, 2,0,0,0, 3,0,4,0])
        c.equal("binary trace format is unchanged", try Data(contentsOf: file), expected)
        c.expect("flush releases prior trace", recorder.flush(to: file) == nil)
        recorder.record(layer: 1, tokens: 1, topK: 2, ids: [3, 4])
        recorder.record(layer: 1, tokens: 1, topK: 2, ids: [3, 4])
        c.expect("capacity failure is explicit", recorder.flush(to: file)?.contains("exceeded") == true)
        c.equal("discard does not overwrite an existing trace", try Data(contentsOf: file), expected)
        recorder.record(layer: 1, tokens: 1, topK: 2, ids: [3, 4])
        let missing = directory.appendingPathComponent("missing/trace")
        c.expect("write failure never reports success", recorder.flush(to: missing)?.hasPrefix("router trace failed:") == true)
        c.expect("failed write releases buffered data", recorder.flush(to: file) == nil)
        for (tokens, topK, ids) in [(Int.max, 2, [Int32(1)]), (1, 2, [Int32(1)]), (1, 1, [Int32(-1)])] {
            recorder.record(layer: 1, tokens: tokens, topK: topK, ids: ids)
            c.expect("invalid diagnostic record is refused", recorder.flush(to: file)?.contains("invalid") == true)
        }
        recorder.record(layer: 1, tokens: 1, topK: 2, ids: [3, 4])
        c.expect("recorder recovers after failure", recorder.flush(to: file)?.hasPrefix("router trace:") == true)
        return c.report()
    }
}
