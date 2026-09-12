import ArgumentParser
import Foundation
import MLX
@_spi(Testing) import Slotstream

struct CompiledModelCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compiled-model-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        guard ProcessInfo.processInfo.environment["SLOTSTREAM_FULL_RESIDENT_MODE"] == "both" else {
            throw ModelError("compiled-model-check requires explicit both resident mode")
        }
        Memory.cacheLimit = 2 * 1024 * 1024 * 1024
        let m = try Qwen4ExpModel(index: CheckpointIndex(dir: model.modelURL), poolSlots: Geometry.totalRecords)
        try m.enableMTP(modelDir: model.modelURL)
        let head = m.mtpHead!
        let chunks = [Array(repeating: [9707, 11, 1246, 525, 498, 30, 220, 16], count: 32).flatMap { $0 }, [17], [18, 19], Array(20...36)]
        let sequence = chunks.flatMap { $0 } + [37]
        var reference: [[MLXArray]] = []
        var failures = 0
        for enabled in [false, true] {
            m.compiledExpertsForTesting(enabled)
            let state = m.makeState(), draftState = MTPState()
            var position = 0
            for (chunk, ids) in chunks.enumerated() {
                let (logits, multi) = m.allLogitsWithMulti(ids, state: state)
                let next = Array(sequence[(position + 1)..<(position + 1 + ids.count)])
                let embedded = m.resident.embed(MLXArray(next.map(Int32.init), [1, ids.count])).asType(.bfloat16)
                let (draft, draftMulti) = head(embedded: embedded, hiddenMulti: multi, rope: m.sharedRope, state: draftState)
                let outputs = [logits, multi, m.draftLogits(draft), draftMulti]
                eval(outputs)
                position += ids.count
                guard state.tokenCount == position, draftState.offset == position else { throw ModelError("state offset mismatch") }
                if !enabled { reference.append(outputs) }
                else {
                    for (piece, out) in outputs.enumerated() {
                        let exact = arrayEqual(out, reference[chunk][piece]).item(Bool.self)
                        let delta = abs(out.asType(.float32) - reference[chunk][piece].asType(.float32)).max().item(Float.self)
                        print("COMPARE chunk=\(chunk) piece=\(piece) exact=\(exact) max_abs=\(delta)")
                        if !exact { failures += 1 }
                    }
                }
            }
            print("PATH compiled=\(enabled) calls=\(m.compiledExpertCallsForTesting)")
            guard (m.compiledExpertCallsForTesting > 0) == enabled else { throw ModelError("compiled path not exercised as intended") }
        }
        reference.removeAll()
        m.pool.resize(to: 640)
        m.compiledExpertsForTesting(false)
        let a = m.lastLogits([9707, 11], state: m.makeState()); eval(a)
        m.compiledExpertsForTesting(true)
        let b = m.lastLogits([9707, 11], state: m.makeState()); eval(b)
        let exact = arrayEqual(a, b).item(Bool.self)
        print("RESIZE exact=\(exact) compiled_calls=\(m.compiledExpertCallsForTesting) active_bytes=\(Memory.activeMemory)")
        guard exact, m.compiledExpertCallsForTesting > 0, Memory.activeMemory < 20_000_000_000 else {
            throw ModelError("resize output, path or retained-memory gate failed")
        }
        print("COMPILED MODEL CHECK \(failures == 0 ? "PASS" : "FAIL"): \(failures)/16 unequal tensors")
        if failures > 0 { throw ExitCode(2) }
    }
}
