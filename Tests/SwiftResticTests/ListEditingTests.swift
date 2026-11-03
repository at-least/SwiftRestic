import Foundation
import Testing

@Suite("List editing")
struct ListEditingTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
    }

    @Test("removing a middle row selects the row that took its place")
    func middleRow() {
        // Four rows: the row that takes the removed one's place is not the
        // last, so "the place" and "the last" stay two different answers.
        var rows = [Row(id: 1), Row(id: 2), Row(id: 3), Row(id: 4)]
        #expect(rows.removeKeepingNeighbourSelected(at: 1) == 3)
        #expect(rows == [Row(id: 1), Row(id: 3), Row(id: 4)])
    }

    @Test("removing the last row selects the new last")
    func lastRow() {
        var rows = [Row(id: 1), Row(id: 2)]
        #expect(rows.removeKeepingNeighbourSelected(at: 1) == 1)
        #expect(rows == [Row(id: 1)])
    }

    @Test("removing the only row leaves nothing selected")
    func onlyRow() {
        var rows = [Row(id: 1)]
        #expect(rows.removeKeepingNeighbourSelected(at: 0) == nil)
        #expect(rows.isEmpty)
    }
}
