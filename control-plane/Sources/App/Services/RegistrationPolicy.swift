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

    static func fromConfiguration(_ configuration: ControlPlaneConfiguration) -> RegistrationPolicy {
        RegistrationPolicy(selfRegistrationEnabled: configuration.bool(.selfRegistrationEnabled)!)
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

    /// Configured in `configure.swift`; tests that skip full configuration get
    /// the documented open-registration default.
    var registrationPolicy: RegistrationPolicy {
        get { storage[RegistrationPolicyKey.self] ?? .init(selfRegistrationEnabled: true) }
        set { setStorageValue(RegistrationPolicyKey.self, to: newValue) }
    }
}

extension Request {
    var registrationPolicy: RegistrationPolicy {
        application.registrationPolicy
    }
}
