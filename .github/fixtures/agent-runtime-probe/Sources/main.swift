import Foundation
import FoundationNetworking
import FoundationXML

// Exercise the same static Foundation/XML/ICU and host curl boundary as the
// agent, including XML XPath and Unicode. No network requests or host changes.
let document = try XMLDocument(xmlString: "<domain><name>strato-π</name></domain>", options: [])
let names = try document.nodes(forXPath: "/domain/name")
precondition(names.first?.stringValue == "strato-π")
let payload = try JSONEncoder().encode(["status": "ready"])
let decoded = try JSONDecoder().decode([String: String].self, from: payload)
precondition(decoded["status"] == "ready")
let date = DateFormatter()
date.locale = Locale(identifier: "en_US_POSIX")
date.timeZone = TimeZone(secondsFromGMT: 0)
date.dateFormat = "yyyy-MM-dd"
precondition(date.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01")
precondition(URLSessionConfiguration.ephemeral.httpMaximumConnectionsPerHost > 0)
print("Static Foundation/XML runtime probe passed")
