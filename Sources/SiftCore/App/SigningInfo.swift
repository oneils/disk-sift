import Foundation
import Security

/// Code signing facts DiskSift needs: Team ID, app groups, Apple-anchored or not.
public struct SigningInfo: Sendable, Equatable {
    public var teamID: String?
    public var appGroups: [String]
    public var isAppleAnchored: Bool

    public init(teamID: String? = nil, appGroups: [String] = [], isAppleAnchored: Bool = false) {
        self.teamID = teamID
        self.appGroups = appGroups
        self.isAppleAnchored = isAppleAnchored
    }

    public static let unsigned = SigningInfo()

    /// Pure parser for the dictionary from `SecCodeCopySigningInformation`. Unsigned (empty) → empty info.
    public static func parse(_ dict: [String: Any]) -> SigningInfo {
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return SigningInfo(teamID: teamID, appGroups: groups)
    }

    /// Reads the signature without validating resources or the executable (full hashing takes minutes on big apps).
    /// An unsigned or unreadable bundle gives `.unsigned`.
    public static func read(_ url: URL) -> SigningInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return .unsigned
        }
        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        var info =
            if SecCodeCopySigningInformation(code, flags, &cfInfo) == errSecSuccess,
                let dict = cfInfo as? [String: Any]
            {
                parse(dict)
            } else {
                SigningInfo.unsigned
            }
        info.isAppleAnchored = isAppleAnchored(code)
        return info
    }

    /// `anchor apple` (not `anchor apple generic`), so Pages/Keynote stay removable.
    private static func isAppleAnchored(_ code: SecStaticCode) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
