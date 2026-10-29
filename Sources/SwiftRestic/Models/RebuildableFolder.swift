import Foundation

/// A folder a build tool or package manager makes beside the file that
/// sets the project up: `build` beside `build.gradle`. The names are the
/// generic ones `ExcludeRule.developer` keeps out of its patterns, since a
/// folder by that name elsewhere can hold the only copy of something; here
/// the file beside it says which tool made it, and each folder found is
/// still the user's call, offered by its path after a backup
/// (`AppModel.rebuildableFolders(planID:)`). Adapted from asimov's list, as
/// tmexclude ships it, less the names a developer group already covers.
struct RebuildableFolderRule: Hashable, Sendable {
    let folder: String
    let manifest: String
    /// Who puts it back, as `ExcludeRule.why` says it.
    let why: String

    init(_ folder: String, _ manifest: String, _ why: String) {
        self.folder = folder
        self.manifest = manifest
        self.why = why
    }

    static let all: [RebuildableFolderRule] = [
        RebuildableFolderRule("build", "build.gradle", "Gradle builds it again"),
        RebuildableFolderRule("build", "build.gradle.kts", "Gradle builds it again"),
        RebuildableFolderRule(".gradle", "build.gradle", "Gradle makes it again"),
        RebuildableFolderRule(".gradle", "build.gradle.kts", "Gradle makes it again"),
        RebuildableFolderRule(".gradle", "settings.gradle", "Gradle makes it again"),
        RebuildableFolderRule(".gradle", "settings.gradle.kts", "Gradle makes it again"),
        RebuildableFolderRule("target", "pom.xml", "Maven builds it again"),
        RebuildableFolderRule("target", "build.sbt", "sbt builds it again"),
        RebuildableFolderRule("build", "pubspec.yaml", "Flutter builds it again"),
        RebuildableFolderRule("build", "setup.py", "setup.py builds it again"),
        RebuildableFolderRule("dist", "setup.py", "setup.py builds it again"),
        RebuildableFolderRule("vendor", "composer.json", "composer install fetches it again"),
        RebuildableFolderRule("vendor", "Gemfile", "bundle install fetches it again"),
        RebuildableFolderRule("vendor", "go.mod", "go mod vendor makes it again"),
        RebuildableFolderRule("deps", "mix.exs", "mix deps.get fetches it again"),
        RebuildableFolderRule("bower_components", "bower.json", "bower install fetches it again"),
        RebuildableFolderRule("Carthage", "Cartfile", "carthage bootstrap fetches it again"),
    ]

    /// Each folder name with its manifests, in the list's order: what the
    /// index is asked (`SnapshotIndex.foldersBesideManifests`).
    static var manifestsByFolder: [String: [String]] {
        var byFolder: [String: [String]] = [:]
        for rule in all { byFolder[rule.folder, default: []].append(rule.manifest) }
        return byFolder
    }

    static func rule(folder: String, manifest: String) -> RebuildableFolderRule? {
        all.first { $0.folder == folder && $0.manifest == manifest }
    }
}

/// One folder a backup holds that a rule matched.
struct RebuildableFolder: Hashable, Sendable, Identifiable {
    /// As the backup recorded it.
    let path: String
    let rule: RebuildableFolderRule

    var id: String { path }

    /// What a plan is offered of `found`: each folder with its rule, less
    /// the ones the plan already skips by their path and the ones the user
    /// chose to keep (`BackupPlan.keptRebuildableFolders`).
    static func offered(_ found: [FolderBesideManifest], to plan: BackupPlan) -> [RebuildableFolder] {
        let skipped = Set(plan.excludePatterns.map { PathKey($0) })
        let kept = Set(plan.keptRebuildableFolders.map { PathKey($0) })
        return found.compactMap { folder in
            guard !skipped.contains(PathKey(ResticService.globEscaped(folder.path))),
                  !kept.contains(PathKey(folder.path)),
                  let rule = RebuildableFolderRule.rule(folder: ResticPath.basename(of: folder.path), manifest: folder.manifest)
            else { return nil }
            return RebuildableFolder(path: folder.path, rule: rule)
        }
    }
}
