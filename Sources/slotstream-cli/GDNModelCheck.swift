import ArgumentParser
import Foundation
import MLX
@_spi(Testing) import Slotstream

struct GDNModelCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gdn-model-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        guard ProcessInfo.processInfo.environment["SLOTSTREAM_FULL_RESIDENT_MODE"] == "both" else {
            throw ModelError("gdn-model-check requires explicit both resident mode")
        }
        Memory.cacheLimit = 2 * 1024 * 1024 * 1024
        let m = try Qwen4ExpModel(index: CheckpointIndex(dir: model.modelURL), poolSlots: Geometry.totalRecords)
        try m.enableMTP(modelDir: model.modelURL)
        let head = m.mtpHead!
        let chunks = [Array(repeating: [9707, 11, 1246, 525, 498, 30, 220, 16], count: 32).flatMap { $0 }, [17], [18, 19], Array(20...36)]
        let sequence = chunks.flatMap { $0 } + [37]
        var reference: [[MLXArray]] = []
        var failures = 0
        for mode in ["off", "norm", "gates", "both"] {
            m.gdnPreparationForTesting(mode)
            let state = m.makeState(), draftState = MTPState()
            var position = 0
            for (chunk, ids) in chunks.enumerated() {
                let (logits, multi) = m.allLogitsWithMulti(ids, state: state)
                let next = Array(sequence[(position + 1)..<(position + 1 + ids.count)])
                let embedded = m.resident.embed(MLXArray(next.map(Int32.init), [1, ids.count])).asType(.bfloat16)
                let (draft, draftMulti) = head(embedded: embedded, hiddenMulti: multi, rope: m.sharedRope, state: draftState)
                let outputs = [logits, multi, m.draftLogits(draft), draftMulti] + m.gdnStateForTesting(state)
                eval(outputs)
                position += ids.count
                guard state.tokenCount == position, draftState.offset == position else { throw ModelError("state offset mismatch") }
                if mode == "off" { reference.append(outputs) }
                else {
                    for (piece, out) in outputs.enumerated() {
                        let exact = arrayEqual(out, reference[chunk][piece]).item(Bool.self)
                        let delta = abs(out.asType(.float32) - reference[chunk][piece].asType(.float32)).max().item(Float.self)
                        print("COMPARE mode=\(mode) chunk=\(chunk) piece=\(piece) exact=\(exact) max_abs=\(delta)")
                        if !exact { failures += 1 }
                    }
                }
            }
            let counts = m.gdnPreparationCallsForTesting
            print("PATH mode=\(mode) norm_calls=\(counts[0]) gate_calls=\(counts[1])")
            guard (counts[0] > 0) == ["norm", "both"].contains(mode),
                  (counts[1] > 0) == ["gates", "both"].contains(mode) else {
                throw ModelError("compiled paths not exercised as intended")
            }
        }
        reference.removeAll()
        m.pool.resize(to: 640)
        m.gdnPreparationForTesting("off")
        let a = m.lastLogits([9707, 11], state: m.makeState()); eval(a)
        for mode in ["norm", "gates", "both"] {
            m.gdnPreparationForTesting(mode)
            let b = m.lastLogits([9707, 11], state: m.makeState()); eval(b)
            let exact = arrayEqual(a, b).item(Bool.self)
            print("RESIZE mode=\(mode) exact=\(exact) active_bytes=\(Memory.activeMemory)")
            guard exact, Memory.activeMemory < 20_000_000_000 else {
                throw ModelError("resize output or retained-memory gate failed")
            }
        }
        print("GDN MODEL CHECK \(failures == 0 ? "PASS" : "FAIL"): \(failures) unequal tensors")
        if failures > 0 { throw ExitCode(2) }
    }
}
