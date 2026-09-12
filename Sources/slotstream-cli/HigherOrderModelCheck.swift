import ArgumentParser
import CryptoKit
import Foundation
import MLX
@_spi(Testing) import Slotstream

// Exact compiler equivalence at real resident shapes, including specialization reuse.
// Digests avoid retaining several complete model-logit matrices in unified memory.
struct HigherOrderModelCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "higher-order-model-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        guard ProcessInfo.processInfo.environment["SLOTSTREAM_FULL_RESIDENT_MODE"] == "both" else {
            throw ModelError("higher-order-model-check requires resident both")
        }
        let normalCache = 2 * 1024 * 1024 * 1024
        Memory.cacheLimit = normalCache
        let prefillMB = Int(ProcessInfo.processInfo.environment["SLOTSTREAM_PREFILL_CACHE_MB"] ?? "")
        let m = try Qwen4ExpModel(index: CheckpointIndex(dir: model.modelURL), poolSlots: Geometry.totalRecords)
        try m.enableMTP(modelDir: model.modelURL)
        let head = m.mtpHead!
        let lengths = [512, 1, 2, 3, 17, 3, 256, 3]
        func digest(_ a: MLXArray) throws -> String {
            let values = a.asType(.float32).asArray(Float.self)
            guard values.allSatisfy({ $0.isFinite }) else { throw ModelError("nonfinite native tensor") }
            var hash = SHA256()
            hash.update(data: Data("\(a.shape):\(a.dtype)".utf8))
            values.withUnsafeBytes { hash.update(bufferPointer: $0) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var comparisons = 0
        for order in 0..<2 {
            let sizes = order == 0 ? lengths : Array(lengths.reversed())
            let chunks = sizes.enumerated().map { chunk, count in
                (0..<count).map { 17 + (($0 + chunk * 7) % 31) }
            }
            let sequence = chunks.flatMap { $0 } + [37]
            var reference: [[String]] = []
            let modes: [(String, Bool)] = order == 0
                ? [("off", false), ("gates", false), ("off", true), ("gates", true)]
                : [("off", false), ("gates", true), ("off", true), ("gates", false)]
            for (mode, experts) in modes {
                m.gdnPreparationForTesting(mode)
                m.compiledExpertsForTesting(experts)
                let state = m.makeState(), draftState = MTPState()
                var position = 0
                for (chunk, ids) in chunks.enumerated() {
                    Memory.cacheLimit = ids.count >= 256 ? (prefillMB.map { $0 << 20 } ?? normalCache) : normalCache
                    let (logits, multi) = m.allLogitsWithMulti(ids, state: state)
                    let next = Array(sequence[(position + 1)..<(position + 1 + ids.count)])
                    let embedded = m.resident.embed(MLXArray(next.map(Int32.init), [1, ids.count])).asType(.bfloat16)
                    let (draft, draftMulti) = head(embedded: embedded, hiddenMulti: multi, rope: m.sharedRope, state: draftState)
                    let outputs = [logits, multi, m.draftLogits(draft), draftMulti] + m.gdnStateForTesting(state)
                    eval(outputs)
                    let hashes = try outputs.map(digest)
                    Memory.cacheLimit = normalCache
                    position += ids.count
                    guard state.tokenCount == position, draftState.offset == position else { throw ModelError("state offset mismatch") }
                    if mode == "off" && !experts { reference.append(hashes) }
                    else {
                        guard hashes.count == reference[chunk].count else { throw ModelError("tensor count changed") }
                        for piece in hashes.indices {
                            guard hashes[piece] == reference[chunk][piece] else {
                                throw ModelError("exact compiler mismatch order=\(order) mode=\(mode) experts=\(experts) chunk=\(chunk) tokens=\(ids.count) piece=\(piece)")
                            }
                            comparisons += 1
                        }
                    }
                    print("CHUNK order=\(order) mode=\(mode) experts=\(experts) tokens=\(ids.count) pieces=\(hashes.count) exact=true offset=\(position)")
                }
                let calls = m.gdnPreparationCallsForTesting
                guard calls[0] == 0, (calls[1] > 0) == (mode == "gates"),
                      (m.compiledExpertCallsForTesting > 0) == experts else {
                    throw ModelError("compiler path coverage mismatch")
                }
                print("PATH order=\(order) mode=\(mode) experts=\(experts) gates=\(calls[1]) expert_calls=\(m.compiledExpertCallsForTesting)")
            }
        }
        m.pool.resize(to: 640)
        m.gdnPreparationForTesting("off"); m.compiledExpertsForTesting(false)
        let original = m.lastLogits([9707, 11, 17], state: m.makeState()); eval(original)
        let originalDigest = try digest(original)
        for (mode, experts) in [("gates", false), ("off", true), ("gates", true)] {
            m.gdnPreparationForTesting(mode); m.compiledExpertsForTesting(experts)
            let result = m.lastLogits([9707, 11, 17], state: m.makeState()); eval(result)
            guard try digest(result) == originalDigest, Memory.activeMemory < 20_000_000_000 else {
                throw ModelError("resize exact output or retained tensor gate failed")
            }
            print("RESIZE mode=\(mode) experts=\(experts) exact=true active=\(Memory.activeMemory)")
        }
        print("HIGHER ORDER MODEL CHECK PASS comparisons=\(comparisons) orders=2 compiler_modes=4 lengths=\(lengths)")
    }
}
