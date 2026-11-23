import Testing
@testable import MacSpaceCore

@Test func largestElementsCapAtFiftyByDefault() {
    let sizes = (1...200).map { UInt64($0) }
    let picked = LargestElements.of(sizes) { $0 }
    #expect(picked.count == 50 && LargestElements.accessibilityLimit == 50)
    #expect(picked == Array((151...200).reversed()))
}

@Test func largestElementsAreBiggestFirstAndKeepAllWhenFewer() {
    #expect(LargestElements.of([3, 9, 1, 7] as [UInt64]) { $0 } == [9, 7, 3, 1])
    #expect(LargestElements.of([] as [UInt64]) { $0 }.isEmpty)
    #expect(LargestElements.of([5] as [UInt64], limit: 0) { $0 }.isEmpty)
}

@Test func largestElementsBreakTiesByInputOrder() {
    let items = [(name: "a", size: 10), (name: "b", size: 10), (name: "c", size: 20),
                 (name: "d", size: 10), (name: "e", size: 10)] as [(name: String, size: UInt64)]
    let picked = LargestElements.of(items, limit: 3) { $0.size }
    #expect(picked.map(\.name) == ["c", "a", "b"])
    #expect(LargestElements.of(items, limit: 3) { $0.size }.map(\.name) == picked.map(\.name))
}
