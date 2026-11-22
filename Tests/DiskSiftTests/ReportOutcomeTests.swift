import Foundation
import SiftCore
import Testing

@testable import DiskSift

@Suite struct ReportOutcomeTests {
    let a = URL(fileURLWithPath: "/x/a")
    let b = URL(fileURLWithPath: "/x/b")

    @Test func fullSuccess() {
        let report = RemovalReport(removed: [RemovedItem(url: a, size: 1)])
        #expect(ReportOutcome(report) == .success)
        #expect(ReportOutcome(report).symbol == "checkmark.circle.fill")
    }

    @Test func partialWhenSomeSkipped() {
        let report = RemovalReport(
            removed: [RemovedItem(url: a, size: 1)], skipped: [SkippedItem(url: b, reason: .inUse)])
        #expect(ReportOutcome(report) == .partial)
        #expect(ReportOutcome(report).titleKey(context: .uninstall) == "Uninstall partly finished")
    }

    @Test func failedWhenNothingRemoved() {
        let report = RemovalReport(skipped: [SkippedItem(url: a, reason: .permissionDenied)])
        #expect(ReportOutcome(report) == .failed)
    }

    @Test func failedWhenAppNotRemovedEvenIfSomethingElseWas() {
        let report = RemovalReport(
            removed: [RemovedItem(url: b, size: 1)], skipped: [SkippedItem(url: a, reason: .appNotRemoved)])
        #expect(ReportOutcome(report) == .failed)
    }

    @Test func stoppedWins() {
        let report = RemovalReport(
            removed: [RemovedItem(url: a, size: 1)],
            unprocessed: [Finding(url: b, confidence: .high, sources: [])], stopped: true)
        #expect(ReportOutcome(report) == .stopped)
        #expect(ReportOutcome(report).titleKey(context: .cleanup) == "Cleanup stopped")
    }

    @Test func stopAfterLastItemIsNotStopped() {
        let report = RemovalReport(removed: [RemovedItem(url: a, size: 1)], stopped: true)
        #expect(ReportOutcome(report) == .success)
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

    @Test func largeFilesTitlesNeverSayUninstall() {
        let outcomes: [ReportOutcome] = [.success, .partial, .stopped, .failed]
        for outcome in outcomes {
            #expect(!outcome.titleKey(context: .largeFiles).contains("Uninstall"))
        }
        #expect(ReportOutcome.success.titleKey(context: .largeFiles) == "Files moved to Trash")
        #expect(ReportOutcome.success.titleKey(context: .uninstall) == "Uninstall finished")
        #expect(ReportOutcome.success.titleKey(context: .cleanup) == "Cleanup finished")
        #expect(ReportContext.largeFiles.policy == .trash)
        for outcome in outcomes { #expect(!outcome.titleKey(context: .leftovers).contains("Uninstall")) }
        #expect(ReportOutcome.success.titleKey(context: .leftovers) == "Leftovers moved to Trash")
        #expect(ReportContext.leftovers.policy == .trash)
        #expect(ReportContext.cleanup.policy == .delete)
    }

    @MainActor @Test func mixedReportShowsBothPolicies() {
        let deleted = RemovedItem(url: a, size: 10)
        let trashed = RemovedItem(url: b, size: 1000)
        let report = RemovalReport(removed: [deleted, trashed])
        let sheet = ReportSheet(
            report: report, context: .cleanup, paths: SiftPaths(root: URL(fileURLWithPath: "/r")), reveal: { _ in },
            removedByPolicy: [.delete: [deleted], .trash: [trashed]], onClose: {})
        #expect(sheet.shownPolicies == [.delete, .trash])
        #expect(sheet.removed(.trash) == [trashed])
        #expect(ReportOutcome(report) == .success)
    }

    @MainActor @Test func singlePolicyReportsFollowTheContext() {
        let item = RemovedItem(url: a, size: 1)
        let paths = SiftPaths(root: URL(fileURLWithPath: "/r"))
        let trash = ReportSheet(
            report: RemovalReport(removed: [item]), context: .largeFiles, paths: paths, reveal: { _ in }, onClose: {})
        #expect(trash.shownPolicies == [.trash])
        #expect(trash.removed(.delete).isEmpty)
        let nothing = ReportSheet(
            report: RemovalReport(skipped: [SkippedItem(url: a, reason: .inUse)]), context: .cleanup, paths: paths,
            reveal: { _ in }, removedByPolicy: [:], onClose: {})
        #expect(nothing.shownPolicies == [.delete])
    }
}
