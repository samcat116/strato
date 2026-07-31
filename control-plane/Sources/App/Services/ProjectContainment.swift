import Foundation
import Vapor

/// The single answer to "the request names two resources that live in
/// different projects" (issue #777).
///
/// Several endpoints refuse this same structural condition — volume attach,
/// security-group attach, floating-IP attach, DNS zone attach. Each was
/// hand-written, and they had drifted across `400`, `403`, and `409`, so no
/// client could branch on status to recognize a containment failure. Route new
/// sites through here rather than writing another comparison.
///
/// **Not every project mismatch belongs here.** Two shapes stay out:
///
/// - *The caller was never authorized against the other resource* — VM create
///   naming a `securityGroupIds` entry, a rule naming a `remoteGroupId`. There
///   is no check to sit behind, so saying "different project" would confirm
///   that an opaque id names a real resource elsewhere. Those scope the lookup
///   to the caller's project and answer plain not-found, the way
///   `LogicalNetworkService.resolveForWorkloadCreate` does for networks.
/// - *The project came from the request path, not the body* —
///   `ImageController`'s `/api/projects/{projectID}/images/{imageID}` guards.
///   A mismatch there means "no such image under this path", which is a `404`,
///   not two resources the caller asked to combine.
///
/// **Why `400`.** The request body names a combination that cannot exist: a
/// malformed request, not an access decision. `403` reads as an access
/// statement and misdescribes the failure, because the caller may hold full
/// rights on both objects — that is exactly the case this guard exists for
/// (issue #766). Nothing is in conflict and no retry helps, so `409` fits
/// least of all.
///
/// **Call it after the authorization checks on both resources.** Comparing
/// projects first turns the refusal into a project-membership oracle: a caller
/// with no rights on the other resource could tell "that lives in another
/// project" apart from "that isn't visible to you". Authorizing first means
/// the containment message only ever reaches a caller who could already see
/// both sides.
enum ProjectContainment {

    /// Refuses the request unless both resources belong to the same project.
    ///
    /// `subject` and `object` are spliced into
    /// "<subject> belongs to a different project than <object>", so they read
    /// as a sentence: `"Volume"` and `"the VM"`.
    static func require(
        _ subject: String, in subjectProject: UUID,
        sameProjectAs object: String, in objectProject: UUID
    ) throws {
        guard subjectProject == objectProject else {
            throw Abort(.badRequest, reason: "\(subject) belongs to a different project than \(object)")
        }
    }
}
