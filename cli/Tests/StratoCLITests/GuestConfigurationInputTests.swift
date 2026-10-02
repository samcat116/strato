import Foundation
import Testing
@testable import StratoCLICore

@Suite("Guest configuration input")
struct GuestConfigurationInputTests {
    @Test func generatedContractUsesSharedValidation() throws {
        let value = try GuestConfigurationInput.decode(
            Data(
                "{\"packages\":[{\"name\":\"curl\",\"state\":\"present\"}],\"files\":[],\"services\":[],\"sysctls\":[]}"
                    .utf8))
        #expect(value.guestConfig?.value1.packages.first?.name == "curl")
    }
    @Test func withdrawingManagementEncodesAnExplicitEmptyConfiguration() throws {
        let request = try GuestConfigurationInput.withdrawal()
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let config = try #require(object["guestConfig"] as? [String: Any])
        for section in ["packages", "files", "services", "sysctls"] {
            #expect((config[section] as? [Any])?.isEmpty == true)
        }
    }
    @Test(arguments: [
        "{}", "null", "{\"packages\":[],\"files\":[],\"services\":[],\"sysctls\":[],\"bad\":\"STR92_SECRET_SENTINEL\"}",
        "{\"packages\":[{\"name\":\"STR92_SECRET_SENTINEL;id\",\"state\":\"present\"}],\"files\":[],\"services\":[],\"sysctls\":[]}",
    ])
    func invalidInputDoesNotEchoValues(_ json: String) throws {
        do {
            _ = try GuestConfigurationInput.decode(Data(json.utf8))
            Issue.record("Expected invalid guest configuration")
        } catch {
            #expect(!String(describing: error).contains("STR92_SECRET_SENTINEL"))
        }
    }
    @Test func oversizedInputIsBounded() {
        #expect(throws: CLIError.self) {
            try GuestConfigurationInput.decode(Data(repeating: 65, count: GuestConfigurationInput.maxDocumentBytes + 1))
        }
    }
}
