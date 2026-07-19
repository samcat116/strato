import Foundation

/// Classification of caller-supplied cloud-init user data.
///
/// Cloud-init dispatches user data to a handler based on the first line of the
/// payload, so both sides of the wire need the same detection: the control
/// plane validates that a create request's `userData` starts with a header
/// cloud-init will actually act on (rejecting, say, a shell script missing its
/// shebang), and the agent labels the payload's MIME part with the matching
/// content type when it composes the NoCloud seed.
public enum CloudInitUserDataFormat: String, CaseIterable, Sendable {
    case cloudConfig = "text/cloud-config"
    case cloudConfigArchive = "text/cloud-config-archive"
    case cloudConfigJSONP = "text/cloud-config-jsonp"
    case shellScript = "text/x-shellscript"
    case includeURL = "text/x-include-url"
    case includeOnceURL = "text/x-include-once-url"
    case bootHook = "text/cloud-boothook"
    case partHandler = "text/part-handler"
    /// A `## template: jinja` document; cloud-init renders the template and
    /// re-dispatches on the header underneath.
    case jinjaTemplate = "text/jinja2"
    /// A complete MIME document the caller composed themselves (single part or
    /// multipart). It cannot be embedded as a part of another multipart, so the
    /// agent uses it as the NoCloud `user-data` verbatim.
    case mime

    /// The MIME content type the payload should be labeled with when embedded
    /// as a part of a multipart user-data document. Nil for `.mime`, which is
    /// never embedded.
    public var mimeType: String? {
        self == .mime ? nil : rawValue
    }

    /// Header-prefix table, ordered so longer prefixes win over their own
    /// prefixes (`#include-once` before `#include`, `#cloud-config-archive`
    /// before `#cloud-config`).
    private static let prefixes: [(String, CloudInitUserDataFormat)] = [
        ("#cloud-config-archive", .cloudConfigArchive),
        ("#cloud-config-jsonp", .cloudConfigJSONP),
        ("#cloud-config", .cloudConfig),
        ("#include-once", .includeOnceURL),
        ("#include", .includeURL),
        ("#cloud-boothook", .bootHook),
        ("#part-handler", .partHandler),
        ("#!", .shellScript),
        ("## template:", .jinjaTemplate),
    ]

    /// Detects the payload's format from its first line, mirroring cloud-init's
    /// own starts-with dispatch. Returns nil when the payload carries no header
    /// cloud-init recognizes (it would be silently ignored in the guest).
    public static func detect(_ userData: String) -> CloudInitUserDataFormat? {
        for (prefix, format) in prefixes where userData.hasPrefix(prefix) {
            return format
        }
        // A caller-composed MIME document: RFC 5322 headers at the top. Match
        // the two headers a valid cloud-init MIME payload must lead with.
        let lowered = userData.lowercased()
        if lowered.hasPrefix("content-type:") || lowered.hasPrefix("mime-version:") {
            return .mime
        }
        return nil
    }

    /// Upper bound the control plane enforces on `userData` (the NoCloud seed
    /// has no protocol limit; this guards the database and the wire).
    public static let maxBytes = 64 * 1024
}
