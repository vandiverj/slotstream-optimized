// Experimental, model-owned pure functions: no cache, state or weights captured.
import Foundation
import MLX
import MLXNN

final class GDNPreparationKernel {
    var mode: String
    var normCalls = 0
    var gateCalls = 0
    private let normalizeFunction: @Sendable ([MLXArray]) -> [MLXArray]
    private let gateFunction: @Sendable ([MLXArray]) -> [MLXArray]

    init(cfg: ModelConfig, mode: String) {
        self.mode = mode
        let scale = Float(pow(Double(cfg.linearKHeadDim), -0.5))
        normalizeFunction = compile { a in [l2normQK(a[0]) * scale, l2normQK(a[1])] }
        gateFunction = compile { a in
            [computeGatedDeltaG(a[2], a[0], a[3]), sigmoid(a[1]).asType(.float32)]
        }
    }
    var normEnabled: Bool { mode == "norm" || mode == "both" }
    var gatesEnabled: Bool { mode == "gates" || mode == "both" }
    func normalize(_ q: MLXArray, _ k: MLXArray) -> [MLXArray] {
        normCalls += 1
        return normalizeFunction([q, k])
    }
    func gates(_ a: MLXArray, _ b: MLXArray, _ aLog: MLXArray, _ dtBias: MLXArray) -> [MLXArray] {
        gateCalls += 1
        return gateFunction([a, b, aLog, dtBias])
    }
}
