// Candidate-only deterministic controller; instantiated anew per generation.
struct AdaptiveDraftPolicy {
    private(set) var depth = 1
    private var rounds = 0
    private var accepted = 0

    mutating func observe(acceptedDrafts: Int) {
        precondition(acceptedDrafts >= 0 && acceptedDrafts <= depth)
        rounds += 1
        accepted += acceptedDrafts
        guard rounds == 16 else { return }
        depth = accepted >= (depth == 1 ? 14 : 24) ? 2 : 1
        rounds = 0
        accepted = 0
    }
}
