import Foundation

/// The plan editor's line naming what every plan leaves out.
enum PlanSkips {
    static let always = "Always excluded: caches, system files, developer files, the Trash and online-only files."

    static var alwaysHelp: String {
        ExcludeRule.defaults.map { "\($0.pattern) — \($0.what)" }.joined(separator: "\n")
            + "\nWhat developer tools download or build again"
            + "\nFolders holding a CACHEDIR.TAG file"
            + "\nFiles kept only in iCloud Drive or OneDrive"
    }
}
