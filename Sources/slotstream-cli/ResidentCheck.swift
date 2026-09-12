// Candidate-only checks; standard tests must not silently bypass the new path.
import ArgumentParser
import Foundation
import MLX
@_spi(Testing) import Slotstream

struct ResidentMapCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resident-map-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        let index = try CheckpointIndex(dir: model.modelURL)
        let order = [5, 1, 7, 0, 3, 2, 6, 4]
        func makePool() throws -> SlotPool {
            let p = SlotPool(slots: 8, store: try ExpertStore(index: index))
            let staged = p.pools.enumerated().map { piece, a in
                broadcast(MLXArray((0..<8).map { Int32(piece * 16 + $0 + 1) })
                    .asType(a.dtype).reshaped([8, 1, 1]), to: a.shape)
            }
            eval(staged)
            p.admit(layer: 0, experts: order, rows: Array(0..<8), from: staged)
            p.commitAdmissions()
            try p.installResidentMapForTesting(layers: 1, experts: 8)
            try p.residentModeForTesting("both")
            return p
        }
        let p = try makePool()
        let ids: [Int32] = [5, 0, 5, 7, 3, 1, 6, 2]
        let actual = p.residentIndicesForTesting(layer: 0, ids: MLXArray(ids, [1, 2, 4]))!
        let expected = MLXArray(ids.map { Int32(order.firstIndex(of: Int($0))!) }, [1, 2, 4])
        guard arrayEqual(actual, expected).item(Bool.self) else { throw ModelError("resident mapping mismatch") }
        for piece in p.pools {
            guard arrayEqual(piece[actual], piece[expected]).item(Bool.self) else {
                throw ModelError("resident gathered bytes differ")
            }
        }
        p.resize(to: 7)
        guard !p.residentMapReadyForTesting,
              p.residentIndicesForTesting(layer: 0, ids: MLXArray([Int32(0)])) == nil else {
            throw ModelError("resize retained a stale map")
        }
        let q = try makePool()
        _ = q.ensure([ExpertKey(0, 8)])
        guard !q.residentMapReadyForTesting else { throw ModelError("miss retained a stale map") }
        do {
            try q.installResidentMapForTesting(layers: 1, experts: 8)
            throw ModelError("incomplete map was accepted")
        } catch let error as ModelError {
            if String(describing: error).contains("incomplete map was accepted") { throw error }
        }
        print("RESIDENT MAP CHECK PASS: noncanonical slots, repeated indices, all nine pieces, resize and miss invalidation")
    }
}

struct FullResidentCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "full-resident-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        guard ProcessInfo.processInfo.environment["SLOTSTREAM_FULL_RESIDENT_MODE"] == "preload" else {
            throw ModelError("full-resident-check requires explicit preload mode")
        }
        let m = try Qwen4ExpModel(index: CheckpointIndex(dir: model.modelURL), poolSlots: Geometry.totalRecords)
        try m.enableMTP(modelDir: model.modelURL)
        let head = m.mtpHead!
        let chunks = [Array(repeating: [9707, 11, 1246, 525, 498, 30, 220, 16], count: 32).flatMap { $0 }, [17], [18, 19], [20, 21, 22]]
        let sequence = chunks.flatMap { $0 } + [20]
        var reference: [[MLXArray]] = []
        var failures = 0
        for mode in ["preload", "gpu", "defer", "both"] {
            try m.pool.residentModeForTesting(mode)
            m.pool.resetStats()
            let state = m.makeState()
            let draftState = MTPState()
            var position = 0
            for (chunk, ids) in chunks.enumerated() {
                let (logits, multi) = m.allLogitsWithMulti(ids, state: state)
                let next = Array(sequence[(position + 1)..<(position + 1 + ids.count)])
                let embedded = m.resident.embed(MLXArray(next.map(Int32.init), [1, ids.count])).asType(.bfloat16)
                let (draft, draftMulti) = head(embedded: embedded, hiddenMulti: multi, rope: m.sharedRope, state: draftState)
                let outputs = [logits, multi, m.draftLogits(draft), draftMulti]
                eval(outputs)
                position += ids.count
                guard state.tokenCount == position, draftState.offset == position else { throw ModelError("state offset differs") }
                if mode == "preload" { reference.append(outputs) }
                else {
                    for (piece, out) in outputs.enumerated() {
                        let equal = arrayEqual(out, reference[chunk][piece]).item(Bool.self)
                        let delta = abs(out.asType(.float32) - reference[chunk][piece].asType(.float32)).max().item(Float.self)
                        print("COMPARE \(mode) chunk=\(chunk) piece=\(piece) exact=\(equal) max_abs=\(delta)")
                        if !equal { failures += 1 }
                    }
                }
            }
            let gpu = m.pool.residentGPUSelections
            let deferred = m.pool.residentDeferredLayers
            print("PATH \(mode) gpu_selections=\(gpu) deferred_layers=\(deferred)")
            guard (gpu > 0) == (mode == "gpu" || mode == "both"),
                  (deferred > 0) == (mode == "defer" || mode == "both") else {
                throw ModelError("intended experimental path did not execute")
            }
        }
        m.pool.resetStats()
        var hooks = 0
        let observed = m.hiddenStates([9707], state: m.makeState(), perLayerHook: { _, _ in hooks += 1 })
        eval(observed)
        guard hooks == Geometry.layers, m.pool.residentDeferredLayers == 0 else { throw ModelError("external hook did not retain barriers") }
        let before = m.lastLogits([9707], state: m.makeState()); eval(before)
        m.pool.resize(to: 640)
        m.pool.resetStats()
        let after = m.lastLogits([9707], state: m.makeState()); eval(after)
        guard !m.pool.residentMapReadyForTesting, m.pool.residentGPUSelections == 0,
              m.pool.residentDeferredLayers == 0, arrayEqual(before, after).item(Bool.self) else {
            throw ModelError("small-cache fallback after resize changed output or used stale map")
        }
        print("FULL RESIDENT CHECK \(failures == 0 ? "PASS" : "FAIL"): \(failures) unequal tensors; external hooks and resize fallback checked")
        if failures > 0 { throw ExitCode(2) }
    }
}
