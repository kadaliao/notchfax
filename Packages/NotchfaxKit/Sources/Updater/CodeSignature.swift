import Foundation
import Security

/// Who signed a copy of the app, and whether a downloaded copy was signed the same way.
///
/// An update is only installed when it carries a valid Developer ID signature from the
/// same team, for the same bundle identifier, as the app that is running. That is what
/// makes a download trustworthy; the checksum only catches a broken transfer.
enum CodeSignature {
    struct Signer: Equatable, Sendable {
        var identifier: String
        var team: String
    }

    /// The running app's signer, or `nil` for an unsigned or ad-hoc build, which cannot
    /// tell a genuine update from any other download.
    static func runningApp() -> Signer? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signer(of: staticCode)
    }

    static func signer(ofBundle url: URL) -> Signer? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return signer(of: code)
    }

    private static func signer(of code: SecStaticCode) -> Signer? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              isPlain(identifier), isPlain(team)
        else { return nil }
        return Signer(identifier: identifier, team: team)
    }

    /// Developer ID Application, issued by Apple to `signer.team`, for `signer.identifier`.
    static func requirement(for signer: Signer) -> String {
        """
        anchor apple generic and identifier "\(signer.identifier)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(signer.team)"
        """
    }

    /// Checks every file in the bundle against its signature, and the signature against
    /// `requirement(for:)`. Throws a short reason when anything is off.
    static func verify(bundle url: URL, signedLike signer: Signer) throws(UpdateError) {
        guard isPlain(signer.identifier), isPlain(signer.team) else { throw .signature("签名信息不对") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw .signature("读不出新版本的签名")
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement(for: signer) as CFString, [], &compiled) == errSecSuccess, let compiled else {
            throw .signature("签名要求写错了")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &error)
        guard status == errSecSuccess else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "错误 \(status)"
            throw .signature(status == errSecCSReqFailed ? "不是同一位开发者签的名" : reason)
        }
    }

    /// Identifiers and team IDs are dotted ASCII; anything else would change the requirement's meaning.
    private static func isPlain(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }
}
