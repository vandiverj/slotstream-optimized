// Candidate-only regression check of the actual SlotPool admission path.
// Eight real-shape slots and synthetic tensor contents; no model generation.
import ArgumentParser
import Foundation
import MLX
@_spi(Testing) import Slotstream

struct AdmissionCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admission-check",
        abstract: "Check admission bytes across contiguous, wrapped and pinned destinations")
    @OptionGroup var model: ModelOptions

    func run() throws {
        let index = try CheckpointIndex(dir: model.modelURL)
        let modes: [Bool?] = [nil, false, true]
        for mode in modes {
            print("Admission mode: \(mode.map { $0 ? "slice" : "indexed" } ?? "automatic")")
            let pool = SlotPool(slots: 8, store: try ExpertStore(index: index), admissionSlicesForTesting: mode)
            let staged = pool.pools.enumerated().map { piece, array in
                broadcast(
                    MLXArray((0 ..< 8).map { Int32(16 * piece + $0 + 1) })
                        .asType(array.dtype).reshaped([8, 1, 1]),
                    to: array.shape)
            }
            eval(staged)
            var expected: [Int: Int] = [:]
            var comparisons = 0
            func require(_ condition: Bool, _ message: String) throws {
                if !condition { throw ModelError(message) }
            }
            func check(_ label: String) throws {
                let keys = expected.keys.sorted().filter { pool.isResident(ExpertKey(0, $0)) }
                let actual = pool.gatherResident(keys.map { ExpertKey(0, $0) })
                for (position, expert) in keys.enumerated() {
                    for piece in 0 ..< 9 {
                        try require(
                            arrayEqual(actual[piece][position], staged[piece][expected[expert]!]).item(Bool.self),
                            "\(label): changed bytes for expert \(expert), piece \(piece)")
                        comparisons += 1
                    }
                }
                print("PASS \(label): \(keys.count) resident keys, all nine pieces")
            }
            func admit(_ experts: [Int], _ rows: [Int], _ label: String) throws {
                for (expert, row) in zip(experts, rows) where !pool.isResident(ExpertKey(0, expert)) {
                    expected[expert] = row
                }
                pool.admit(layer: 0, experts: experts, rows: rows, from: staged)
                pool.commitAdmissions()
                try require(experts.allSatisfy { pool.isResident(ExpertKey(0, $0)) }, "new admission missing")
                try check(label)
            }
            try admit([0, 1, 2], [5, 1, 7], "contiguous destinations with shuffled source rows")
            try admit([], [], "empty admission preserves contents")
            try admit([0, 3, 4], [0, 2, 6], "resident key is preserved while new keys enter")
            try admit([5, 6], [3, 0], "fill toward pool end")
            try admit([7, 8, 9], [1, 0, 3], "wrapped destination fallback")
            try require(pool.ensure([ExpertKey(0, 7), ExpertKey(0, 8), ExpertKey(0, 9)]) == [7, 0, 1],
                        "wrap fixture did not exercise nonconsecutive destinations")
            pool.unpinAll()
            _ = pool.ensure([ExpertKey(0, 3), ExpertKey(0, 5)])
            try admit([10, 11, 12], [6, 7, 4], "pinned-hole destination fallback")
            try require(pool.isResident(ExpertKey(0, 3)) && pool.isResident(ExpertKey(0, 5)),
                        "admission evicted a pinned key")
            try require(pool.ensure([ExpertKey(0, 10), ExpertKey(0, 11), ExpertKey(0, 12)]) == [2, 4, 6],
                        "pinned-hole fixture did not exercise nonconsecutive destinations")
            pool.unpinAll()
            print("ADMISSION CHECK PASS: \(comparisons) full-tensor comparisons")
        }
    }
}
