// Candidate-only probe; production GDN execution remains unchanged.
import Foundation
import MLX
import MLXNN

public enum GDNPreparationProbe {
    public static func run(modelURL: URL) throws -> Bool {
        Memory.cacheLimit = 2 * 1024 * 1024 * 1024
        let index = try CheckpointIndex(dir: modelURL)
        let w = try ResidentWeights(index: index)
        let cfg = w.config
        let scale = Float(pow(Double(cfg.linearKHeadDim), -0.5))
        let normalize: ([MLXArray]) -> [MLXArray] = { a in
            [l2normQK(a[0]) * scale, l2normQK(a[1])]
        }
        let gates: ([MLXArray]) -> [MLXArray] = { a in
            [computeGatedDeltaG(a[2], a[0], a[3]), sigmoid(a[1]).asType(.float32)]
        }
        let compiledNorm = compile(normalize)
        let compiledGates = compile(gates)
        var failures = 0, comparisons = 0
        let layers = (0..<cfg.numLayers).filter {
            w.has("model.layers.\($0).linear_attn.in_proj_qkv.weight")
        }.prefix(2)
        guard layers.count == 2 else { throw ModelError("expected two GDN layers") }
        for layer in layers {
            let base = "model.layers.\(layer).linear_attn"
            let keyDim = cfg.linearNumKHeads * cfg.linearKHeadDim
            let valueDim = cfg.linearNumVHeads * cfg.linearVHeadDim
            let convDim = 2 * keyDim + valueDim
            for length in [1, 2, 17, 256] {
                for variant in 0..<3 {
                    let values = (0..<(length * cfg.hiddenSize)).map {
                        variant == 2 ? Float(0) : Float((($0 * 17 + variant * 23) % 101) - 50) / 32
                    }
                    let x = MLXArray(values, [1, length, cfg.hiddenSize]).asType(.bfloat16)
                    let mixed = w.linear(base + ".in_proj_qkv")(x)
                    let convState = MLXArray.zeros([1, cfg.convKernel - 1, convDim], dtype: x.dtype)
                    let convInput = concatenated([convState, mixed], axis: 1)
                    let convOut = MLXNN.silu(conv1d(convInput, w.tensor(base + ".conv1d.weight"), groups: convDim))
                    let q = convOut[.ellipsis, 0..<keyDim].reshaped([1, length, cfg.linearNumKHeads, cfg.linearKHeadDim])
                    let k = convOut[.ellipsis, keyDim..<(2 * keyDim)].reshaped(q.shape)
                    let ni = [q, k]
                    let gi = [w.linear(base + ".in_proj_a")(x), w.linear(base + ".in_proj_b")(x), w.tensor(base + ".A_log"), w.tensor(base + ".dt_bias")]
                    eval(ni); eval(gi)
                    let expected = normalize(ni) + gates(gi)
                    eval(expected)
                    for mode in (variant % 2 == 0 ? ["A", "B", "AB"] : ["AB", "B", "A"]) {
                        let actual = (mode == "B" ? normalize(ni) : compiledNorm(ni))
                            + (mode == "A" ? gates(gi) : compiledGates(gi))
                        eval(actual)
                        for i in expected.indices {
                            let delta = abs(expected[i].asType(.float32) - actual[i].asType(.float32)).max().item(Float.self)
                            let exact = arrayEqual(expected[i], actual[i]).item(Bool.self)
                            let finite = expected[i].asArray(Float.self).allSatisfy { $0.isFinite }
                                && actual[i].asArray(Float.self).allSatisfy { $0.isFinite }
                            print("COMPARE layer=\(layer) length=\(length) variant=\(variant) mode=\(mode) piece=\(i) exact=\(exact) finite=\(finite) max_abs=\(delta)")
                            comparisons += 1
                            if !exact || !finite { failures += 1 }
                        }
                    }
                }
            }
        }
        print("GDN PREPARATION CHECK \(failures == 0 ? "PASS" : "FAIL"): \(failures)/\(comparisons) unequal or nonfinite tensors")
        return failures == 0
    }
}
