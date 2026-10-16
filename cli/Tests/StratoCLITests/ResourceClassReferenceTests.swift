import Foundation
import Testing
@testable import StratoCLICore

@Suite("CLI resource class references")
struct ResourceClassReferenceTests {
    @Test func omittedReferencePreservesDefaultAndPartialReferenceFails() throws {
        #expect(try parseResourceClassReference(site: nil, classID: nil) == nil)
        #expect(throws: CLIError.self) { try parseResourceClassReference(site: UUID().uuidString, classID: nil) }
        #expect(throws: CLIError.self) { try parseResourceClassReference(site: "invalid", classID: UUID().uuidString) }
        let site = UUID().uuidString
        let classID = "00000000-0000-0000-0000-000000000001"
        let parsed = try #require(try parseResourceClassReference(site: site, classID: classID))
        #expect(parsed.siteID == site)
        #expect(parsed.classID == classID)
    }
}
