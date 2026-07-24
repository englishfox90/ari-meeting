//
//  EmailValidationTests.swift — the authored-email guard that closes the 2026-07-23
//  duplicate-Ryan hole (a display name landing in the identity-key field).
//
import Foundation
import Testing
@testable import AriKit

@Suite("EmailValidation")
struct EmailValidationTests {

    @Test("normalized trims and lowercases, maps empty/whitespace to nil")
    func normalizes() {
        #expect(EmailValidation.normalized("  Ryan.Chadwick@Arivo.com ") == "ryan.chadwick@arivo.com")
        #expect(EmailValidation.normalized("") == nil)
        #expect(EmailValidation.normalized("   ") == nil)
        #expect(EmailValidation.normalized(nil) == nil)
    }

    @Test("isValid accepts plausible addresses")
    func acceptsValid() {
        #expect(EmailValidation.isValid("ryan.chadwick@arivo.com"))
        #expect(EmailValidation.isValid("a@b.co"))
        #expect(EmailValidation.isValid("first.last@sub.domain.org"))
    }

    @Test("isValid rejects the incident value and other non-emails")
    func rejectsNonEmails() {
        #expect(!EmailValidation.isValid("Ryan Chadwick")) // the exact incident
        #expect(!EmailValidation.isValid("ryan.chadwick"))
        #expect(!EmailValidation.isValid("ryan@arivo"))     // no dot in domain
        #expect(!EmailValidation.isValid("@arivo.com"))
        #expect(!EmailValidation.isValid("ryan@@arivo.com"))
        #expect(!EmailValidation.isValid("ryan @arivo.com")) // internal whitespace
        #expect(!EmailValidation.isValid(""))
    }
}
