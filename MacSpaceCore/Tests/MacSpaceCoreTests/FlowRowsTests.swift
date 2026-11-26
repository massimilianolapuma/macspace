import Testing
@testable import MacSpaceCore

/// Rows of every subset of `widths`, in every order, by brute force (small inputs only).
private func bruteForceWorstCase(_ widths: [Double], spacing: Double, width: Double) -> Int {
    func permutations(_ items: [Double]) -> [[Double]] {
        guard !items.isEmpty else { return [[]] }
        return items.indices.flatMap { i in
            var rest = items
            let item = rest.remove(at: i)
            return permutations(rest).map { [item] + $0 }
        }
    }
    var worst = 0
    for mask in 0..<(1 << widths.count) {
        let subset = widths.indices.filter { mask & (1 << $0) != 0 }.map { widths[$0] }
        for order in permutations(subset) {
            worst = max(worst, FlowRows.rows(order, spacing: spacing, width: width))
        }
    }
    return worst
}

@Test func flowRowsWrapsWhenTheNextItemDoesNotFit() {
    #expect(FlowRows.rows([], spacing: 10, width: 100) == 0)
    #expect(FlowRows.rows([40, 50], spacing: 10, width: 100) == 1)       // 40 + 10 + 50 = 100 fits
    #expect(FlowRows.rows([40, 51], spacing: 10, width: 100) == 2)
    #expect(FlowRows.rows([150, 20], spacing: 10, width: 100) == 2)      // too wide: alone on its row
    #expect(FlowRows.rows([30, 30, 30, 30], spacing: 5, width: 100) == 2)
}

/// Another order can need more rows than the given one: [60, 30, 60, 30] fits in two rows of 100,
/// [60, 60, 30, 30] needs three. The worst case matches a brute force over every subset and order.
@Test func flowRowsWorstCaseCoversEveryOrderAndSubset() {
    #expect(FlowRows.rows([60, 30, 60, 30], spacing: 0, width: 100) == 2)
    #expect(FlowRows.worstCase([60, 30, 60, 30], spacing: 0, width: 100) == 3)
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<60 {
        let count = Int.random(in: 1...6, using: &generator)
        let widths = (0..<count).map { _ in Double(Int.random(in: 10...120, using: &generator)) }
        let spacing = Double(Int.random(in: 0...16, using: &generator))
        let width = Double(Int.random(in: 60...300, using: &generator))
        #expect(FlowRows.worstCase(widths, spacing: spacing, width: width)
                    == bruteForceWorstCase(widths, spacing: spacing, width: width),
                "\(widths) spacing \(spacing) width \(width)")
    }
}
