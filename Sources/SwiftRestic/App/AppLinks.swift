import Foundation

/// Pinned by a test: a typo surfaces as a red suite instead of a dead
/// menu item.
enum AppLinks {
    static let documentation = URL(string: "https://restic.readthedocs.io")!
    static let changelog = URL(string: "https://restic.readthedocs.io/en/stable/changelog.html")!
}
