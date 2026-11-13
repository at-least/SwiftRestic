import SwiftUI

extension View {
    /// A plan's page's Overview | Backups in the middle of the window
    /// toolbar: the HIG's center area for switching a main window's view,
    /// clear of the trailing corner, where the search field sits.
    func pageTabPicker(_ selection: Binding<PageTab>, tabs: [PageTab]) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: selection) {
                    // The View menu’s words too (⌘1–⌘2).
                    ForEach(tabs, id: \.self) { tab in
                        Text(tab.menuTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 80 * CGFloat(tabs.count))
            }
        }
    }
}

extension View {
    /// Every page's search, in the window toolbar's trailing field (the
    /// HIG's place for it): its first keystroke turns the page to Search
    /// All Backups, the query in that page's field in the same place,
    /// answered as it is typed. ⌘F opens Search All Backups itself.
    func allBackupsSearch() -> some View {
        modifier(AllBackupsSearchField())
    }
}

private struct AllBackupsSearchField: ViewModifier {
    @Environment(AppRouter.self) private var router
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: Text("Search all backups"))
            .onChange(of: text) { _, typed in
                guard !typed.isEmpty else { return }
                router.openFind(query: typed)
                text = ""
            }
    }
}
