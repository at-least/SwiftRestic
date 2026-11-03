import Foundation

/// The plan editor's *Skip* switches by the names the editor and the plan
/// page's Excluding card both give them.
enum PlanSkips {
    static let finderFiles = "Finder files and the Trash"
    static let systemFiles = "App caches and system files"
    static let caches = "Folders marked as caches"
    static let developerFiles = "Developer files"
    static let cloudFiles = "Online-only files"
    static let cloudFilesCaption = "Files kept only in iCloud Drive or OneDrive aren’t downloaded or backed up."
    static let timeMachineExclusions = "Items excluded from Time Machine"
    static let timeMachineExclusionsCaption = "The items listed in Time Machine’s options."
    static let timeMachineExclusionsFullDiskAccessHint = "To read that list, turn on SwiftRestic in Full Disk Access."
    static let otherDisks = "Other disks mounted inside"

    static let cachesHelp = "Folders holding a CACHEDIR.TAG file"

    static func rulesHelp(_ categories: Set<ExcludeCategory>) -> String {
        ExcludeRule.defaults
            .filter { categories.contains($0.category) }
            .map { "\($0.pattern) — \($0.what)" }
            .joined(separator: "\n")
    }

    /// The switches `plan` has on, in the editor's order. Help is nil where
    /// the title itself says it: a partly-ticked Developer files names its
    /// groups in its title, and Other disks repeats its switch's name.
    static func on(in plan: BackupPlan) -> [(title: String, help: String?)] {
        var items: [(title: String, help: String?)] = []
        if plan.skipsFinderFiles { items.append((finderFiles, rulesHelp(ExcludeCategory.finderFiles))) }
        if plan.skipsSystemFiles { items.append((systemFiles, rulesHelp(ExcludeCategory.systemFiles))) }
        if plan.excludeCaches { items.append((caches, cachesHelp)) }
        if plan.excludeDeveloperFiles {
            let groups = plan.developerGroups.map(\.title)
            let isAll = plan.developerGroups == ExcludeCategory.developerGroups
            items.append((isAll ? developerFiles : "\(developerFiles): \(Format.list(groups))", isAll ? groups.joined(separator: "\n") : nil))
        }
        if plan.excludeCloudFiles { items.append((cloudFiles, "Files kept only in iCloud Drive or OneDrive")) }
        if plan.skipsTimeMachineExclusions { items.append((timeMachineExclusions, timeMachineExclusionsCaption)) }
        if plan.oneFileSystem { items.append((otherDisks, nil)) }
        return items
    }
}
