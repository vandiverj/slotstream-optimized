// Experimental, model-owned pure callable. Never capture pool buffers here:
// admission and resizing replace them, and a capture would become stale/retained.
import MLX
import MLXNN

final class CachedExpertKernel {
    var enabled: Bool
    var calls = 0
    private let function: @Sendable ([MLXArray]) -> [MLXArray]

    init(cfg: ModelConfig, enabled: Bool) {
        self.enabled = enabled
        let group = cfg.qGroup, bits = cfg.qBits
        function = compile { a in
            let xe = a[0].expandedDimensions(axes: [-2, -3])
            let g = gatherQuantizedMM(xe, a[2], scales: a[3], biases: a[4],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            let u = gatherQuantizedMM(xe, a[5], scales: a[6], biases: a[7],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            let hidden = MLXNN.silu(g) * u
            let d = gatherQuantizedMM(hidden, a[8], scales: a[9], biases: a[10],
                rhsIndices: a[1], transpose: true, groupSize: group, bits: bits)
            return [d.squeezed(axis: -2)]
        }
    }

    func callAsFunction(_ x: MLXArray, indices: MLXArray, pieces: [MLXArray]) -> MLXArray {
        calls += 1
        return function([x, indices] + pieces)[0]
    }
}
