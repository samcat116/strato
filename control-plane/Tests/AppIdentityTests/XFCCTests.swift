import Foundation
import Testing
@testable import App

/// Tests for the X-Forwarded-Client-Cert header parser used to authenticate
/// agents behind the Envoy mTLS sidecar. The parser must survive quoted values
/// (Subject can contain `,`/`;`/`=`), multi-hop headers, and URL-encoded
/// certificate payloads.
@Suite("XFCC Header Parsing")
struct XFCCTests {

    @Test("Parses a typical Envoy XFCC element")
    func parsesTypicalElement() throws {
        let header =
            "By=spiffe://strato.local/control-plane;"
            + "Hash=468ed33be74eee6556d90c0149c1309e9ba61d6425303443c0748a02dd8de688;"
            + "URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
        #expect(element.hash == "468ed33be74eee6556d90c0149c1309e9ba61d6425303443c0748a02dd8de688")
        #expect(element.certPEM == nil)
        #expect(element.chainPEM == nil)
    }

    @Test("Quoted Subject containing semicolons and commas does not derail parsing")
    func handlesQuotedSubject() throws {
        let header =
            "By=spiffe://strato.local/control-plane;"
            + "Subject=\"CN=agent;O=Strato,C=US\";"
            + "URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.subject == "CN=agent;O=Strato,C=US")
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
    }

    @Test("Escaped quotes inside a quoted value are unescaped")
    func handlesEscapedQuotes() throws {
        let header = "Subject=\"CN=\\\"agent\\\"\";URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.subject == "CN=\"agent\"")
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
    }

    @Test("Multi-hop header resolves to the nearest (last) element")
    func multiHopTakesLastElement() throws {
        let header =
            "URI=spiffe://forged.example/agent/evil,"
            + "By=spiffe://strato.local/control-plane;URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
    }

    @Test("Commas inside quoted values do not split elements")
    func quotedCommaDoesNotSplitElements() throws {
        let header = "Subject=\"O=first,hop\";URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
        #expect(element.subject == "O=first,hop")
    }

    @Test("Cert and Chain values are URL-decoded to PEM")
    func decodesURLEncodedCertificates() throws {
        let pem = "-----BEGIN CERTIFICATE-----\nMIIB+zCCAY2gAwIBAgIUFAKE\n-----END CERTIFICATE-----\n"
        let encoded = try #require(
            pem.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let header = "Cert=\"\(encoded)\";Chain=\"\(encoded)\";URI=spiffe://strato.local/agent/agent-1"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.certPEM == pem)
        #expect(element.chainPEM == pem)
    }

    @Test("Keys are matched case-insensitively")
    func caseInsensitiveKeys() throws {
        let header = "uri=spiffe://strato.local/agent/agent-1;hash=abc"
        let element = try #require(XFCCElement.parseNearestHop(header: header))
        #expect(element.uri == "spiffe://strato.local/agent/agent-1")
        #expect(element.hash == "abc")
    }

    @Test("Header without key/value pairs parses to nil")
    func meaninglessHeaderIsNil() {
        #expect(XFCCElement.parseNearestHop(header: "") == nil)
        #expect(XFCCElement.parseNearestHop(header: "   ") == nil)
        #expect(XFCCElement.parseNearestHop(header: "no-pairs-here") == nil)
    }

    @Test("Element with no URI still parses; uri accessor is nil")
    func missingURIIsNil() throws {
        let element = try #require(XFCCElement.parseNearestHop(header: "Hash=abc"))
        #expect(element.uri == nil)
    }
}
