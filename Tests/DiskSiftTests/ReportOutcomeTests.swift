import Foundation
import SiftCore
import Testing

@testable import DiskSift

@Suite struct ReportOutcomeTests {
    let a = URL(fileURLWithPath: "/x/a")
    let b = URL(fileURLWithPath: "/x/b")

    @Test func fullSuccess() {
        let report = RemovalReport(removed: [RemovedItem(url: a, size: 1)])
        #expect(ReportOutcome(report, policy: .delete) == .success)
        #expect(ReportOutcome(report, policy: .delete).symbol == "checkmark.circle.fill")
    }

    @Test func partialWhenSomeSkipped() {
        let report = RemovalReport(
            removed: [RemovedItem(url: a, size: 1)], skipped: [SkippedItem(url: b, reason: .inUse)])
        #expect(ReportOutcome(report, policy: .trash) == .partial)
        #expect(ReportOutcome(report, policy: .trash).titleKey(policy: .trash) == "Uninstall partly finished")
    }

    @Test func failedWhenNothingRemoved() {
        let report = RemovalReport(skipped: [SkippedItem(url: a, reason: .permissionDenied)])
        #expect(ReportOutcome(report, policy: .delete) == .failed)
    }

    @Test func failedWhenAppNotRemovedEvenIfSomethingElseWas() {
        let report = RemovalReport(
            removed: [RemovedItem(url: b, size: 1)], skipped: [SkippedItem(url: a, reason: .appNotRemoved)])
        #expect(ReportOutcome(report, policy: .trash) == .failed)
    }

    @Test func stoppedWins() {
        let report = RemovalReport(
            removed: [RemovedItem(url: a, size: 1)],
            unprocessed: [Finding(url: b, confidence: .high, sources: [])], stopped: true)
        #expect(ReportOutcome(report, policy: .delete) == .stopped)
        #expect(ReportOutcome(report, policy: .delete).titleKey(policy: .delete) == "Cleanup stopped")
    }

    @Test func stopAfterLastItemIsNotStopped() {
        let report = RemovalReport(removed: [RemovedItem(url: a, size: 1)], stopped: true)
        #expect(ReportOutcome(report, policy: .delete) == .success)
    }

    @Test func everySkipReasonHasATitle() {
        let reasons: [SkipReason] = [
            .outsideRoots, .needsAdmin, .permissionDenied, .inUse, .vanished, .appNotRemoved, .notAFile,
            .policyNotAllowed,
        ]
        #expect(reasons.allSatisfy { !$0.titleKey.isEmpty })
        #expect(SkipReason.vanished.hintKey == nil)
        #expect(SkipReason.inUse.hintKey != nil)
    }
}
