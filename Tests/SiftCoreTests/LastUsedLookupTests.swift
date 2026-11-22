import Foundation
import Testing

@testable import SiftCore

@Suite struct LastUsedLookupTests {
    /// Spotlight's indexing state varies, so only check that the call is safe.
    @Test func spotlightLookupIsSafeOnFreshAndMissingFiles() throws {
        let fx = try Fixture()
        let file = try fx.write("home/Downloads/new.bin", "x")
        let lookup = SpotlightLastUsedLookup()
        _ = lookup.lastUsed(file)
        #expect(lookup.lastUsed(fx.url("home/Downloads/missing.bin")) == nil)
    }

    @Test func fakeReturnsConfiguredDates() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let lookup = FakeLastUsedLookup(dates: ["/a": date])
        #expect(lookup.lastUsed(URL(fileURLWithPath: "/a")) == date)
        #expect(lookup.lastUsed(URL(fileURLWithPath: "/b")) == nil)
    }
}
