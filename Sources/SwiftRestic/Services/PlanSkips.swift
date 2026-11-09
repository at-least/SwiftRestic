import Foundation

/// The plan editor's *Also exclude* rows by the names it gives them.
enum PlanSkips {
    static let always = "Caches, system files, the Trash and online-only files"
    static let developerFiles = "Developer files"
    static let developerFilesCaption = "What developer tools download or build again."
    static let machines = "Simulators, containers and virtual machines"
    static let machinesCaption = "Whatever is inside them isn’t backed up."

    static var alwaysHelp: String {
        ExcludeRule.defaults.map { "\($0.pattern) — \($0.what)" }.joined(separator: "\n")
            + "\nFolders holding a CACHEDIR.TAG file"
            + "\nFiles kept only in iCloud Drive or OneDrive"
    }
}
