// Candidate-only numerical rejection screen; does not change inference behavior.
import ArgumentParser
import Foundation
import MLX
import MLXNN
import Slotstream

struct ExpertCompileCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "expert-compile-check")
    @OptionGroup var model: ModelOptions
    func run() throws {
        Memory.cacheLimit = 2 * 1024 * 1024 * 1024
        let index = try CheckpointIndex(dir: model.modelURL)
        let cfg = index.config
        let group = cfg.qGroup, bits = cfg.qBits
        let pool = SlotPool(slots: 8, store: try ExpertStore(index: index))
        let eager: ([MLXArray]) -> [MLXArray] = { a in
            let xe = a[0].expandedDimensions(axes: [-2, -3])
            let g = gatherQuantizedMM(xe, a[2], scales: a[3], biases: a[4],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            let u = gatherQuantizedMM(xe, a[5], scales: a[6], biases: a[7],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            let hidden = MLXNN.silu(g) * u
            let d = gatherQuantizedMM(hidden, a[8], scales: a[9], biases: a[10],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            return [g, u, hidden, d.squeezed(axis: -2)]
        }
        let compiled = compile(eager)
        let compiledFinal = compile { (a: [MLXArray]) -> [MLXArray] in [eager(a)[3]] }
        var failures = 0, comparisons = 0
        for epoch in 0..<2 {
            let experts = epoch == 0 ? [5, 1, 7, 0, 3, 2, 6, 4] : [13, 9, 15, 8, 11, 10, 14, 12]
            let slots = pool.ensure(experts.map { ExpertKey(0, $0) })
            eval(pool.pools)
            for length in [1, 2, 17] {
                for variant in 0..<2 {
                    let values = (0..<(length * cfg.hiddenSize)).map {
                        Float((($0 * 17 + variant * 23) % 101) - 50) / 32
                    }
                    let x = MLXArray(values, [1, length, cfg.hiddenSize]).asType(.bfloat16)
                    let ids = (0..<(length * cfg.topK)).map { Int32(slots[($0 * 3) % 8]) }
                    let inputs = [x, MLXArray(ids, [1, length, cfg.topK])] + pool.pools
                    let a = eager(inputs), b = compiled(inputs)
                    let final = compiledFinal(inputs)
                    eval(a); eval(b); eval(final)
                    let finalExact = arrayEqual(a[3], final[0]).item(Bool.self)
                    let finalDelta = abs(a[3].asType(.float32) - final[0].asType(.float32)).max().item(Float.self)
                    print("FINAL epoch=\(epoch) length=\(length) variant=\(variant) exact=\(finalExact) max_abs=\(finalDelta)")
                    comparisons += 1
                    if !finalExact { failures += 1 }
                    for i in a.indices {
                        let exact = arrayEqual(a[i], b[i]).item(Bool.self)
                        let delta = abs(a[i].asType(.float32) - b[i].asType(.float32)).max().item(Float.self)
                        print("COMPARE epoch=\(epoch) length=\(length) variant=\(variant) piece=\(i) exact=\(exact) max_abs=\(delta)")
                        comparisons += 1
                        if !exact { failures += 1 }
                    }
                }
            }
            pool.unpinAll()
        }
        print("EXPERT COMPILE CHECK \(failures == 0 ? "PASS" : "FAIL"): \(failures)/\(comparisons) unequal tensors")
        if failures > 0 { throw ExitCode(2) }
    }
}
