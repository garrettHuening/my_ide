import XCTest
@testable import CCHSubagents

final class MergeOrderTests: XCTestCase {
    private let a = makeSubagent(id: 1, state: .merged, groupID: 9, index: 1)
    private let b = makeSubagent(id: 2, state: .idle, groupID: 9, index: 2)
    private let c = makeSubagent(id: 3, state: .running, groupID: 9, index: 3)

    func testAppending() {
        XCTAssertEqual(MergeOrder.appending(4, to: [a, b, c]), [1: 1, 2: 2, 3: 3, 4: 4])
        XCTAssertEqual(MergeOrder.appending(9, to: []), [9: 1])
    }

    func testAppendingDropsDiscardedAndClosesGaps() {
        let gone = makeSubagent(id: 1, state: .discarded, groupID: 9, index: 1)
        XCTAssertEqual(MergeOrder.appending(4, to: [gone, b]), [2: 1, 4: 2])
    }

    func testInsertingNeverJumpsAheadOfMerged() {
        XCTAssertEqual(MergeOrder.inserting(4, at: 1, into: [a, b, c]), [1: 1, 4: 2, 2: 3, 3: 4])
    }

    func testInsertingInTheMiddleAndPastTheEnd() {
        XCTAssertEqual(MergeOrder.inserting(4, at: 3, into: [a, b, c]), [1: 1, 2: 2, 4: 3, 3: 4])
        XCTAssertEqual(MergeOrder.inserting(4, at: 99, into: [a, b, c]), [1: 1, 2: 2, 3: 3, 4: 4])
    }

    func testReorderingKeepsMergedFirstAndAppendsUnmentioned() {
        XCTAssertEqual(MergeOrder.reordering([c, b, a], requested: [3, 2]), [1: 1, 3: 2, 2: 3])
        XCTAssertEqual(MergeOrder.reordering([a, b, c], requested: [3]), [1: 1, 3: 2, 2: 3])
    }

    func testReorderingAcceptsNewIDsAndIgnoresDuplicatesAndMerged() {
        XCTAssertEqual(MergeOrder.reordering([a, b, c], requested: [4, 1, 4, 2]), [1: 1, 4: 2, 2: 3, 3: 4])
    }

    func testRemoving() {
        XCTAssertEqual(MergeOrder.removing(2, from: [a, b, c]), [1: 1, 3: 2])
    }
}
