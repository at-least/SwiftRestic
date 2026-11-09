/// The identifiers the UI tests find elements by. The UI test target compiles
/// this file too (project.yml), so a renamed identifier fails its build.
enum AccessibilityID {
    enum Welcome {
        static let backUpAFolder = "welcome.backUpAFolder"
    }

    enum FirstBackup {
        static let source = "firstBackup.source"
        static let changeSource = "firstBackup.changeSource"
        static let disk = "firstBackup.disk"
        static let password = "firstBackup.password"
        static let confirmPassword = "firstBackup.confirmPassword"
        static let requirement = "firstBackup.requirement"
        static let backUp = "firstBackup.backUp"
    }

    enum Plan {
        static let total = "plan.total"
        static let backUpNow = "plan.backUpNow"
        static let edit = "plan.edit"
        static let runs = "plan.runs"
        static let nextBackup = "plan.nextBackup"
    }

    enum PlanEditor {
        static let save = "planEditor.save"
        static let frequency = "planEditor.frequency"
    }

    enum PathList {
        static let add = "pathList.add"
    }

    enum FilesPane {
        static let restore = "filesPane.restore"
    }

    enum FilesSearch {
        static let results = "filesSearch.results"
    }

    enum FileVersions {
        static let list = "fileVersions.list"
        static let restore = "fileVersions.restore"
    }

    enum RepositoryEditor {
        static let chooseFolder = "repositoryEditor.chooseFolder"
        static let password = "repositoryEditor.password"
        static let confirmPassword = "repositoryEditor.confirmPassword"
        static let requirement = "repositoryEditor.requirement"
        static let save = "repositoryEditor.save"
    }

    enum Repository {
        static let size = "repository.size"
    }

    enum Activity {
        static let table = "activity.table"
    }

    enum RestoreSheet {
        static let chooseFolder = "restoreSheet.chooseFolder"
        static let restore = "restoreSheet.restore"
    }
}
