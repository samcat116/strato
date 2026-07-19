import Foundation
import StratoShared
import Testing

@Suite("Cloud-init user-data format detection")
struct CloudInitUserDataTests {
    @Test func detectsCloudConfig() {
        #expect(CloudInitUserDataFormat.detect("#cloud-config\npackages: [nginx]") == .cloudConfig)
    }

    /// Longer headers that share a prefix with `#cloud-config` must not be
    /// misclassified as plain cloud-config.
    @Test func longerHeadersWinOverTheirPrefixes() {
        #expect(
            CloudInitUserDataFormat.detect("#cloud-config-archive\n- type: text/x-shellscript") == .cloudConfigArchive)
        #expect(CloudInitUserDataFormat.detect("#cloud-config-jsonp\n[]") == .cloudConfigJSONP)
        #expect(CloudInitUserDataFormat.detect("#include-once\nhttps://example.com/a") == .includeOnceURL)
        #expect(CloudInitUserDataFormat.detect("#include\nhttps://example.com/a") == .includeURL)
    }

    @Test func detectsShellScript() {
        #expect(CloudInitUserDataFormat.detect("#!/bin/bash\necho hi") == .shellScript)
        #expect(CloudInitUserDataFormat.detect("#!/usr/bin/env python3\nprint(1)") == .shellScript)
    }

    @Test func detectsBootHookAndPartHandler() {
        #expect(CloudInitUserDataFormat.detect("#cloud-boothook\n#!/bin/sh\necho hi") == .bootHook)
        #expect(CloudInitUserDataFormat.detect("#part-handler\ndef list_types(): ...") == .partHandler)
    }

    @Test func detectsJinjaTemplate() {
        #expect(
            CloudInitUserDataFormat.detect("## template: jinja\n#cloud-config\nhostname: {{ v1.local_hostname }}")
                == .jinjaTemplate)
    }

    @Test func detectsCallerComposedMIME() {
        let mime = """
            Content-Type: multipart/mixed; boundary="xyz"
            MIME-Version: 1.0

            --xyz
            """
        #expect(CloudInitUserDataFormat.detect(mime) == .mime)
        #expect(CloudInitUserDataFormat.detect("MIME-Version: 1.0\nContent-Type: text/cloud-config") == .mime)
        // Header matching is case-insensitive, as RFC 5322 headers are.
        #expect(CloudInitUserDataFormat.detect("content-type: multipart/mixed; boundary=b") == .mime)
    }

    @Test func unrecognizedPayloadsDetectAsNil() {
        #expect(CloudInitUserDataFormat.detect("echo missing shebang") == nil)
        #expect(CloudInitUserDataFormat.detect("packages: [nginx]") == nil)
        #expect(CloudInitUserDataFormat.detect("") == nil)
        #expect(CloudInitUserDataFormat.detect("   \n\t  ") == nil)
    }

    /// Cloud-init's `type_from_starts_with` lowercases and strips leading
    /// whitespace before matching; a payload it would process must not be
    /// rejected here (detection-only normalization — payloads travel verbatim).
    @Test func normalizesLikeCloudInit() {
        #expect(CloudInitUserDataFormat.detect("\n#cloud-config\npackages: [nginx]") == .cloudConfig)
        #expect(CloudInitUserDataFormat.detect("  \t#!/bin/sh\ntrue") == .shellScript)
        #expect(CloudInitUserDataFormat.detect("#Cloud-Config\npackages: [nginx]") == .cloudConfig)
        #expect(CloudInitUserDataFormat.detect("#INCLUDE\nhttps://example.com/a") == .includeURL)
        #expect(CloudInitUserDataFormat.detect("\n## Template: jinja\n#cloud-config\n") == .jinjaTemplate)
    }

    @Test func mimeTypeMapping() {
        #expect(CloudInitUserDataFormat.cloudConfig.mimeType == "text/cloud-config")
        #expect(CloudInitUserDataFormat.shellScript.mimeType == "text/x-shellscript")
        #expect(CloudInitUserDataFormat.jinjaTemplate.mimeType == "text/jinja2")
        #expect(CloudInitUserDataFormat.mime.mimeType == nil)
    }
}
