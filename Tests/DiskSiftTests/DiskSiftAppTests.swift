import Foundation
import Testing

@testable import DiskSift

@Suite struct DiskSiftAppTests {
    @Test(arguments: [
        ("/Applications/DiskSift.app", true),
        ("/Users/x/projects/disk-sift/.build/debug", false),
    ])
    func isBundled(path: String, expected: Bool) {
        #expect(DiskSiftApp.isBundled(URL(fileURLWithPath: path)) == expected)
    }
}
