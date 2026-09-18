import Foundation
import Testing

/// The restore-name sanitizer: snapshot node names are repository data, and a
/// hostile writer to a shared repository can fill them with anything. Wherever
/// the app turns a name into a local path (`dump`'s output file, the drag's
/// staged file), the traversal spellings must never survive.
@Suite("restore name sanitizing")
struct RestoreSanitizingTests {
    @Test("ordinary names pass through untouched")
    func plainNamesSurvive() {
        #expect(ResticService.sanitizedRestoreName("invoice.pdf") == "invoice.pdf")
        #expect(ResticService.sanitizedRestoreName("My Backups 2026") == "My Backups 2026")
        #expect(ResticService.sanitizedRestoreName("..hidden") == "..hidden")
    }

    @Test("traversal spellings cannot name a path outside the destination")
    func traversalIsDefused() {
        #expect(ResticService.sanitizedRestoreName("../evil") == "evil")
        #expect(ResticService.sanitizedRestoreName("../../evil") == "evil")
        #expect(ResticService.sanitizedRestoreName("/etc/passwd") == "passwd")
        #expect(ResticService.sanitizedRestoreName("folder/evil") == "evil")
        #expect(ResticService.sanitizedRestoreName("..") == "restored")
        #expect(ResticService.sanitizedRestoreName(".") == "restored")
        #expect(ResticService.sanitizedRestoreName("") == "restored")
        #expect(ResticService.sanitizedRestoreName("/") == "restored")
    }
}
