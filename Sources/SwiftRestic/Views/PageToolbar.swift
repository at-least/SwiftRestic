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
    /// A plan's page's search, in the window toolbar's trailing field (the
    /// HIG's place for it): the plan's files across every backup. Typed on
    /// Overview, the page turns to Backups, where the hits list. ⌘F focuses
    /// it (`AppRouter.searchFocus`).
    func pageSearch(page: SidebarItem, roots: FileNode?) -> some View {
        modifier(PageSearch(page: page, roots: roots))
    }

    /// The toolbar's field on a page other than a plan's: its first keystroke
    /// turns the page to Search All Backups, the query in that page's field
    /// in the same place, answered as it is typed — as a plan's page turns
    /// to its Backups tab.
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

private struct PageSearch: ViewModifier {
    @Environment(AppRouter.self) private var router
    let page: SidebarItem
    /// The chain the tab lists; nil for a plan with no repository, which has
    /// nothing to search.
    let roots: FileNode?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: text, placement: .toolbar, prompt: Text(verbatim: "Search this plan’s backups"))
            .searchFocused($isFocused)
            .onChange(of: router.searchFocus, initial: true) { _, asked in
                guard asked == page else { return }
                router.searchFocus = nil
                // A turn later: ⌘F may have switched the tab in this update,
                // and the field takes the focus once it is there.
                Task { @MainActor in isFocused = true }
            }
    }

    private var text: Binding<String> {
        Binding(
            get: { roots.flatMap { router.filesSearchText[$0] } ?? "" },
            set: { newValue in
                guard let roots else { return }
                router.filesSearchText[roots] = newValue
                if !newValue.isEmpty, router.tab(of: page) != .backups {
                    router.setTab(.backups, of: page)
                }
            }
        )
    }
}
