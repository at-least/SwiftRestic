import Foundation

/// The plan editor's *Skip* switches by the names the editor and the plan
/// page's Excluding card both give them.
enum PlanSkips {
    static let always = "Caches, system files and the Trash"
    static let developerFiles = "Developer files"
    static let developerFilesCaption = "What developer tools download or build again."
    static let machines = "Simulators, containers and virtual machines"
    static let machinesCaption = "Whatever is inside them isn’t backed up."
    static let cloudFiles = "Online-only files"
    static let cloudFilesCaption = "Files kept only in iCloud Drive or OneDrive aren’t downloaded or backed up."

    static var alwaysHelp: String {
        ExcludeRule.defaults.map { "\($0.pattern) — \($0.what)" }.joined(separator: "\n")
            + "\nFolders holding a CACHEDIR.TAG file"
    }

    /// What `plan` leaves out besides its own patterns, in the editor's order.
    static func on(in plan: BackupPlan) -> [(title: String, help: String?)] {
        var items: [(title: String, help: String?)] = [(always, alwaysHelp)]
        if plan.skipsDeveloperFiles { items.append((developerFiles, developerFilesCaption)) }
        if plan.skipsMachines { items.append((machines, machinesCaption)) }
        if plan.excludeCloudFiles { items.append((cloudFiles, "Files kept only in iCloud Drive or OneDrive")) }
        return items
    }
}
