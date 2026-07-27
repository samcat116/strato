import Fluent
import Foundation
import Vapor

/// Whether an unauthenticated visitor may create their own account.
///
/// Self-registration is open by default — that is how a fresh install gets its
/// first user. Operators who provision accounts themselves (admin invite links
/// or SSO) close it with `SELF_REGISTRATION_ENABLED=false`, which hides the
/// login page's "Create one" link *and* refuses `POST /api/users/register`;
/// hiding the link alone would leave the endpoint open to anyone who typed the
/// URL.
///
/// Bootstrap is the one exception. An installation with no users has no admin
/// who could invite anybody, so closing the door there would lock everyone out
/// permanently. The first account can therefore always be created, whatever the
/// setting says; the moment it exists the door closes again.
struct RegistrationPolicy: Sendable {
    /// The operator's setting, verbatim. Bootstrap overrides it — ask
    /// ``allowsRegistration(bootstrapRequired:)`` rather than reading this to
    /// decide whether a given request may proceed.
    let selfRegistrationEnabled: Bool

    /// Environment variable that drives the setting.
    static let environmentKey = "SELF_REGISTRATION_ENABLED"

    /// Open unless explicitly switched off.
    ///
    /// Accepts the usual falsy spellings rather than only Swift's `Bool.init`,
    /// which parses "true"/"false" and nothing else: an operator who writes
    /// `SELF_REGISTRATION_ENABLED=0` means to close registration, and silently
    /// leaving it open would be the worst possible reading of that.
    static func parse(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else {
            return true
        }
        return !["false", "0", "no", "off"].contains(value)
    }

    static func fromEnvironment() -> RegistrationPolicy {
        RegistrationPolicy(selfRegistrationEnabled: parse(Environment.get(environmentKey)))
    }

    /// The effective answer for right now: the setting, or bootstrap.
    func allowsRegistration(bootstrapRequired: Bool) -> Bool {
        selfRegistrationEnabled || bootstrapRequired
    }
}

/// What the login page needs to decide whether to offer account creation.
///
/// Public and unauthenticated, like the SSO discovery routes next to it: the
/// login page asks before any session exists.
struct RegistrationPolicyResponse: Content {
    /// Whether `POST /api/users/register` will accept an account right now.
    /// Already accounts for bootstrap, so the client can render on it directly.
    let selfRegistrationEnabled: Bool
    /// Whether this installation has no users yet, i.e. the next account
    /// created is the first one and becomes the system admin. Lets the login
    /// page say so instead of offering a generic sign-up.
    let bootstrapRequired: Bool
}

// MARK: - Application Extension

extension Application {
    struct RegistrationPolicyKey: StorageKey {
        typealias Value = RegistrationPolicy
    }

    /// Configured in `configure.swift`; falls back to the environment so a test
    /// application that never ran `configure` still gets the real default.
    var registrationPolicy: RegistrationPolicy {
        get { storage[RegistrationPolicyKey.self] ?? .fromEnvironment() }
        set { setStorageValue(RegistrationPolicyKey.self, to: newValue) }
    }
}

extension Request {
    var registrationPolicy: RegistrationPolicy {
        application.registrationPolicy
    }
}
