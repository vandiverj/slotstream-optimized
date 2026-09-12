// Router traces, so the cache simulator can finally be fed real data.
//
// M1 — the expert-locality study — has been open since the beginning: the
// simulator (`Tools/cachesim.py`) and the collector for the Python reference
// (`Tools/trace_routers.py`) were both built in 2026-08, but no trace was ever
// taken from a bounded forward pass, because at the time no bounded forward
// pass existed. It does now, and the decode split says 44% of decode time at a
// small cache is reading expert records, so which records the cache keeps is
// the question that decides that number.
//
// `SLOTSTREAM_ROUTER_TRACE=<path>` records every routing decision the model
// makes and writes it on exit. The format is a flat stream a reader
// reassembles: per MoE call, `layer`, `tokens`, `topK` as little-endian int32,
// then `tokens * topK` int16 expert ids. Layers are visited in order within a
// pass, so a reader groups by pass without needing a pass id.
//
// The trace is off unless the variable is set, and reading it costs one static
// Bool per MoE call.

import Foundation

public enum RouterTrace {
    public static let path: String? =
        ProcessInfo.processInfo.environment["SLOTSTREAM_ROUTER_TRACE"]
    public static let on: Bool = path != nil

    private static let recorder = RouterTraceRecorder()

    public static func record(layer: Int, tokens: Int, topK: Int, ids: [Int32]) {
        guard on else { return }
        recorder.record(layer: layer, tokens: tokens, topK: topK, ids: ids)
    }

    /// Called by the CLI at the end of generation. Failure is reported rather
    /// than presenting a missing or partial trace as successful diagnostic data.
    @discardableResult
    public static func flush() -> String? {
        guard on, let path else { return nil }
        return recorder.flush(to: URL(fileURLWithPath: path))
    }
}

/// Owns one bounded diagnostic trace. Separate from the environment switch so
/// file failures and capacity exhaustion can be exercised without a model.
package final class RouterTraceRecorder {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var calls = 0
    private var uses = 0
    private var failure: String?

    package init(limit: Int = 64 << 20) { self.limit = max(0, limit) }

    package func record(layer: Int, tokens: Int, topK: Int, ids: [Int32]) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        let (count, overflow) = tokens.multipliedReportingOverflow(by: topK)
        guard layer >= 0, tokens >= 0, topK >= 0,
              Int32(exactly: layer) != nil, Int32(exactly: tokens) != nil,
              Int32(exactly: topK) != nil, !overflow, count == ids.count,
              ids.allSatisfy({ $0 >= 0 && $0 <= Int32(Int16.max) }) else {
            discard("invalid routing record")
            return
        }
        guard limit - buffer.count >= 12, ids.count <= (limit - buffer.count - 12) / 2 else {
            discard("trace exceeded \(limit) bytes")
            return
        }
        let header = [Int32(layer), Int32(tokens), Int32(topK)]
        header.withUnsafeBytes { buffer.append(contentsOf: $0) }
        let small = ids.map { Int16($0) }
        small.withUnsafeBytes { buffer.append(contentsOf: $0) }
        calls += 1
        uses += ids.count
    }

    private func discard(_ reason: String) {
        failure = reason
        buffer = Data()
        calls = 0
        uses = 0
    }

    package func flush(to url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer = Data(); calls = 0; uses = 0; failure = nil }
        if let failure { return "router trace failed: \(failure); trace discarded" }
        guard !buffer.isEmpty else { return nil }
        do {
            try buffer.write(to: url, options: .atomic)
            return "router trace: \(calls) MoE calls, \(uses) expert-uses -> \(url.path)"
        } catch {
            return "router trace failed: \(error); trace discarded"
        }
    }
}
