/// Rows of a wrapping flow layout (items left to right, a new row when the next one does not
/// fit), as the chart legend lays out its chips.
public enum FlowRows {
    /// Rows needed for `widths` in this order, `spacing` apart, in rows `width` wide. An item wider
    /// than a row takes a row of its own.
    public static func rows(_ widths: [Double], spacing: Double, width: Double) -> Int {
        var rows = 0
        var used = 0.0
        for item in widths {
            if rows > 0, used + spacing + item <= width {
                used += spacing + item
            } else {
                rows += 1
                used = item
            }
        }
        return rows
    }

    /// The most rows any subset of `widths`, in any order, can need: room reserved for this many
    /// rows is never outgrown, whichever items show and however they are sorted. At most 16 items.
    ///
    /// Exact, by dynamic programming over subsets: for each subset it keeps the reachable (rows,
    /// width used in the last row) states that no other state beats on both counts. A fuller last
    /// row never needs fewer rows later (the next row starts no later), so that pruning is safe.
    public static func worstCase(_ widths: [Double], spacing: Double, width: Double) -> Int {
        precondition(widths.count <= 16, "worstCase is exponential in the item count")
        let count = widths.count
        var fronts = [[State]](repeating: [], count: 1 << count)
        fronts[0] = [State(rows: 0, used: 0)]
        var worst = 0
        // A subset's states come only from smaller masks, so each is complete when reached.
        for mask in fronts.indices {
            let front = fronts[mask]
            for state in front { worst = max(worst, state.rows) }
            for item in 0..<count where mask & (1 << item) == 0 {
                for state in front {
                    insert(state.adding(widths[item], spacing: spacing, width: width), into: &fronts[mask | (1 << item)])
                }
            }
        }
        return worst
    }

    private struct State {
        var rows: Int
        var used: Double

        func adding(_ item: Double, spacing: Double, width: Double) -> State {
            rows > 0 && used + spacing + item <= width
                ? State(rows: rows, used: used + spacing + item)
                : State(rows: rows + 1, used: item)
        }

        func beats(_ other: State) -> Bool { rows >= other.rows && used >= other.used }
    }

    private static func insert(_ state: State, into front: inout [State]) {
        guard !front.contains(where: { $0.beats(state) }) else { return }
        front.removeAll { state.beats($0) }
        front.append(state)
    }
}
