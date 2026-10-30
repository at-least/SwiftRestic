import Foundation

extension Array where Element: Identifiable {
    /// Removes the row at `index` and answers the selection that keeps a
    /// neighbour open below the list: the row that took the removed one's
    /// place, else the last — nil when none is left. The Hooks tab's and the
    /// Webhooks tab's lists.
    mutating func removeKeepingNeighbourSelected(at index: Int) -> Element.ID? {
        remove(at: index)
        return indices.contains(index) ? self[index].id : last?.id
    }
}
