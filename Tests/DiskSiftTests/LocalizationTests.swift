import Foundation
import Testing

struct LocalizationTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private static func plist(_ lang: String, _ file: String) throws -> [String: Any] {
        let url = resources.appendingPathComponent("\(lang).lproj/\(file)")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func stringsKeySetsMatch() throws {
        let en = try Self.plist("en", "Localizable.strings")
        let ru = try Self.plist("ru", "Localizable.strings")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(ru.keys))
    }

    @Test func stringsdictKeySetsMatch() throws {
        let en = try Self.plist("en", "Localizable.stringsdict")
        let ru = try Self.plist("ru", "Localizable.stringsdict")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(ru.keys))
    }

    @Test func russianPluralFormsComplete() throws {
        let ru = try Self.plist("ru", "Localizable.stringsdict")
        for (key, value) in ru {
            let entry = try #require(value as? [String: Any], "\(key)")
            let count = try #require(entry["count"] as? [String: Any], "\(key)")
            for form in ["one", "few", "many", "other"] {
                #expect(count[form] is String, "\(key) missing \(form)")
            }
        }
    }
}
