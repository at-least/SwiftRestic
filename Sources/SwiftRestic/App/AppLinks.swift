import Foundation

/// The documentation links the app opens, in one place. Constant literals,
/// but pinned by a test: a typo surfaces as a red suite instead of a dead
/// menu item — or the force-unwrap crash the inline spellings carried.
enum AppLinks {
    static let documentation = URL(string: "https://restic.readthedocs.io")!
    static let changelog = URL(string: "https://restic.readthedocs.io/en/stable/changelog.html")!
}
