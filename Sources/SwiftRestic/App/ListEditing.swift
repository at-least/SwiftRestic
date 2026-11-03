import Foundation

extension Array where Element: Identifiable {
    /// Removes the row at `index` and answers the selection that keeps a
    /// neighbour open below the list.
    mutating func removeKeepingNeighbourSelected(at index: Int) -> Element.ID? {
        remove(at: index)
        return indices.contains(index) ? self[index].id : last?.id
    }
}
