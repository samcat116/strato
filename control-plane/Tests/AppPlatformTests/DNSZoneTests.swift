import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// The DNS record model (issue #770): zone CRUD, zone↔network attachment, the
/// primary-zone pointer, authored records with their conflict rules, VM
/// hostnames, and the derived ∪ authored assembler.
@Suite("DNS Zone Tests", .serialized)
final class DNSZoneTests {

    private func withDNSTestApp(
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "dnsuser",
                email: "dns@example.com",
                displayName: "DNS User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "DNS Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let project = try await builder.createProject(
                name: "DNS Project", description: "DNS tests", organization: org)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, user, org, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func createZone(
        app: Application, token: String, project: Project, name: String = "acme.internal"
    ) async throws -> DNSZoneResponse {
        var created: DNSZoneResponse?
        try await app.test(.POST, "/api/dns-zones") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode([
                "name": name, "projectId": project.id!.uuidString,
            ])
        } afterResponse: { res in
            #expect(res.status == .ok)
            created = try res.content.decode(DNSZoneResponse.self)
        }
        return created!
    }

    /// A VM with one NIC on `network` carrying `address`, plus the hostname it
    /// registers under. Written directly rather than through the API so the
    /// assembler tests don't depend on scheduling.
    @discardableResult
    private func createVM(
        app: Application, project: Project, network: LogicalNetwork,
        hostname: String, addresses: [(String, IPFamily, Int)]
    ) async throws -> VM {
        let builder = TestDataBuilder(db: app.testPostgres)
        var vm = try await builder.createVM(name: hostname, project: project)
        vm.hostname = hostname
        try await vm.save(on: app.testPostgres)
        let networkID = try network.requireID()
        let nic = VMNetworkInterface(
            vmID: try vm.requireID(), logicalNetworkID: networkID,
            macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.testPostgres)
        for (address, family, prefix) in addresses {
            try await LegacyInterfaceAddressStore.insert(
                kind: .vm,
                interfaceID: try nic.requireID(), logicalNetworkID: networkID,
                family: family, address: address, prefixLength: prefix,
                on: app.testPostgres)
        }
        return vm
    }

    // MARK: - Names

    @Test("Zone names are validated as FQDNs and normalized, with no TLD constraint")
    func zoneNameValidation() throws {
        let normalized = try DNSName.normalizedZoneName("ACME.Internal.")
        #expect(normalized == "acme.internal")
        // Deliberately unconstrained: a tenant may serve a public name internally.
        let publicName = try DNSName.normalizedZoneName("corp.example.com")
        #expect(publicName == "corp.example.com")
        #expect(throws: (any Error).self) { try DNSName.normalizedZoneName("internal") }
        #expect(throws: (any Error).self) { try DNSName.normalizedZoneName("-bad.internal") }
        #expect(throws: (any Error).self) { try DNSName.normalizedZoneName("a..internal") }
        #expect(throws: (any Error).self) { try DNSName.normalizedZoneName("under_score.internal") }
    }

    @Test("Hostnames are RFC 1123 labels; slugify produces one from a display name")
    func hostnameValidation() throws {
        let lowered = try DNSName.normalizedHostname("Web-01")
        #expect(lowered == "web-01")
        let leadingDigit = try DNSName.normalizedHostname("0host")
        #expect(leadingDigit == "0host")
        #expect(throws: (any Error).self) { try DNSName.normalizedHostname("web.01") }
        #expect(throws: (any Error).self) { try DNSName.normalizedHostname("-web") }

        #expect(DNSName.slugify("My VM (prod)") == "my-vm-prod")
        #expect(DNSName.slugify("  spaced  out  ") == "spaced-out")
        // Nothing usable survives — still needs somewhere to land.
        #expect(DNSName.slugify("日本語") == "vm")
        #expect(DNSName.slugify(String(repeating: "a", count: 100)).count == 63)
    }

    @Test("Record owner names accept the apex, multi-label names, and wildcards")
    func recordNameValidation() throws {
        // `@` and the empty string are both the apex.
        let apexFromSymbol = try DNSName.normalizedRecordName("@")
        #expect(apexFromSymbol == DNSName.apex)
        let apexFromEmpty = try DNSName.normalizedRecordName("")
        #expect(apexFromEmpty == DNSName.apex)

        let simple = try DNSName.normalizedRecordName("API")
        #expect(simple == "api")
        let multiLabel = try DNSName.normalizedRecordName("api.staging")
        #expect(multiLabel == "api.staging")

        // A bare `*` is the zone-apex wildcard — the common one, and the case
        // that stripping the star leaves nothing behind.
        let apexWildcard = try DNSName.normalizedRecordName("*")
        #expect(apexWildcard == "*")
        let subtreeWildcard = try DNSName.normalizedRecordName("*.api")
        #expect(subtreeWildcard == "*.api")

        #expect(throws: (any Error).self) { try DNSName.normalizedRecordName("-bad") }
        #expect(throws: (any Error).self) { try DNSName.normalizedRecordName("a..b") }
        #expect(throws: (any Error).self) { try DNSName.normalizedRecordName("under_score") }
        // A star anywhere but leftmost is a label, and `*` is not a legal one.
        #expect(throws: (any Error).self) { try DNSName.normalizedRecordName("api.*") }
        #expect(throws: (any Error).self) {
            try DNSName.normalizedRecordName(String(repeating: "a", count: 64))
        }
    }

    @Test("Reverse names follow in-addr.arpa and ip6.arpa")
    func reverseNames() {
        #expect(DNSName.reverseName(forAddress: "192.168.1.10") == "10.1.168.192.in-addr.arpa")
        let v6 = DNSName.reverseName(forAddress: "2001:db8::1")
        #expect(v6?.hasSuffix(".ip6.arpa") == true)
        #expect(v6?.hasPrefix("1.0.0.0.0.0.0.0") == true)
        #expect(v6?.split(separator: ".").count == 34)
    }

    // MARK: - Zone CRUD

    @Test("Zone CRUD, and zone names are unique per project rather than globally")
    func zoneCRUD() async throws {
        try await withDNSTestApp { app, _, org, project, token in
            let zone = try await createZone(app: app, token: token, project: project)
            #expect(zone.name == "acme.internal")
            #expect(zone.recordCount == 0)
            #expect(zone.networks.isEmpty)

            // A second zone with the same name in the same project collides…
            try await app.test(.POST, "/api/dns-zones") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "acme.internal", "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // …but the same name in a *different* project is exactly the
            // split-horizon case the model has to allow.
            let builder = TestDataBuilder(db: app.testPostgres)
            let other = try await builder.createProject(
                name: "Other DNS Project", description: "", organization: org)
            let otherZone = try await createZone(app: app, token: token, project: other)
            #expect(otherZone.name == zone.name)
            #expect(otherZone.id != zone.id)

            try await app.test(.GET, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let fetched = try res.content.decode(DNSZoneResponse.self)
                #expect(fetched.name == "acme.internal")
            }

            try await app.test(.DELETE, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let deleted = try await LegacyDNSZoneStore.find(id: zone.id, on: app.testPostgres)
            #expect(deleted == nil)
        }
    }

    @Test("Attaching a zone to a network grants resolution; primary is a separate choice")
    func attachAndPrimary() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-a", project: project)
            let zone = try await createZone(app: app, token: token, project: project)
            let networkID = try network.requireID()

            // Attach without primary: resolvable, not registered into.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(DNSZoneResponse.self)
                #expect(updated.networks.count == 1)
                #expect(updated.networks[0].isPrimary == false)
            }
            var reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.primaryDNSZoneID == nil)

            // Re-attaching is idempotent and can promote to primary.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let promoted = try res.content.decode(DNSZoneResponse.self)
                #expect(promoted.networks[0].isPrimary == true)
            }
            let attachmentCount = try await DNSZoneNetworkStore.count(on: app.testPostgres)
            #expect(attachmentCount == 1)
            reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.primaryDNSZoneID == zone.id)

            // Detaching the primary would strand its VMs' records.
            try await app.test(.DELETE, "/api/dns-zones/\(zone.id)/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // Deleting an attached zone is refused for the same reason.
            try await app.test(.DELETE, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Clear the primary via the network, then detach.
            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(clearPrimaryDnsZone: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let cleared = try res.content.decode(NetworkResponse.self)
                #expect(cleared.primaryDnsZoneId == nil)
            }
            try await app.test(.DELETE, "/api/dns-zones/\(zone.id)/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("A network's primary zone must already be attached to it")
    func primaryZoneRequiresAttachment() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-b", project: project)
            let zone = try await createZone(app: app, token: token, project: project)
            let networkID = try network.requireID()

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(primaryDnsZoneId: zone.id))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await DNSZoneNetworkStore.attach(zoneID: zone.id, networkID: networkID, on: app.testPostgres)
            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(primaryDnsZoneId: zone.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let promoted = try res.content.decode(NetworkResponse.self)
                #expect(promoted.primaryDnsZoneId == zone.id)
            }
        }
    }

    @Test("A zone can only attach to a network in its own project")
    func attachRejectsForeignNetwork() async throws {
        try await withDNSTestApp { app, _, org, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let other = try await builder.createProject(
                name: "Foreign", description: "", organization: org)
            let foreignNetwork = try await builder.createNetwork(name: "foreign", project: other)
            let zone = try await createZone(app: app, token: token, project: project)

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                let foreignID = try foreignNetwork.requireID()
                try req.content.encode(AttachDNSZoneRequest(networkId: foreignID))
            } afterResponse: { res in
                // The one status every cross-project refusal answers with
                // (issue #777); was 409 here.
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Search domain and delivery (STR-201)

    @Test("The search domain follows the primary zone only while nobody has claimed it")
    func searchDomainFollowsPrimaryZone() {
        // Unset: the zone fills it.
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: nil, previousZoneName: nil, nextZoneName: "acme.internal")
                == "acme.internal")
        // Still spelling the outgoing zone: it moves with the pointer.
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: "acme.internal", previousZoneName: "acme.internal",
                nextZoneName: "corp.internal") == "corp.internal")
        // Demotion clears what followed.
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: "acme.internal", previousZoneName: "acme.internal", nextZoneName: nil)
                == nil)
        // An operator's value outranks every one of those.
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: "chosen.example", previousZoneName: "acme.internal",
                nextZoneName: "corp.internal") == "chosen.example")
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: "chosen.example", previousZoneName: nil, nextZoneName: nil)
                == "chosen.example")
        // Nothing to follow and nothing set: still nothing.
        #expect(
            DNSZoneService.searchDomainFollowingPrimaryZone(
                current: nil, previousZoneName: nil, nextZoneName: nil) == nil)
    }

    @Test("Attaching a zone as primary gives the network its search domain")
    func attachAsPrimarySetsSearchDomain() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-search", project: project)
            let networkID = try network.requireID()
            let zone = try await createZone(app: app, token: token, project: project)

            // Attaching without promoting is not a statement about resolution
            // through the zone, so it leaves the search domain alone.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            var reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.domainName == nil)

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.domainName == "acme.internal")
        }
    }

    @Test("A search domain the operator chose survives promotion, re-pointing and demotion")
    func chosenSearchDomainIsNeverOverwritten() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-chosen", project: project)
            let networkID = try network.requireID()
            let first = try await createZone(app: app, token: token, project: project)
            let second = try await createZone(
                app: app, token: token, project: project, name: "corp.internal")

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(domainName: "chosen.example"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.POST, "/api/dns-zones/\(first.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            var reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.domainName == "chosen.example")

            try await app.test(.POST, "/api/dns-zones/\(second.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.domainName == "chosen.example")

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(clearPrimaryDnsZone: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.domainName == "chosen.example")
        }
    }

    @Test("Re-pointing and clearing the primary zone move a search domain that followed it")
    func followingSearchDomainMovesWithThePointer() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-follow", project: project)
            let networkID = try network.requireID()
            let first = try await createZone(app: app, token: token, project: project)
            let second = try await createZone(
                app: app, token: token, project: project, name: "corp.internal")

            try await app.test(.POST, "/api/dns-zones/\(first.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            // Re-point through the network's own endpoint, the other of the two
            // writers of `primary_dns_zone_id`.
            try await DNSZoneNetworkStore.attach(
                zoneID: second.id, networkID: networkID, on: app.testPostgres)
            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(primaryDnsZoneId: second.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let moved = try res.content.decode(NetworkResponse.self)
                #expect(moved.domainName == "corp.internal")
            }

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(clearPrimaryDnsZone: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let cleared = try res.content.decode(NetworkResponse.self)
                #expect(cleared.domainName == nil)
            }
        }
    }

    @Test("Renaming a primary zone moves only search domains that still follow it")
    func renamingPrimaryZoneMovesFollowingSearchDomains() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let following = try await builder.createNetwork(name: "net-rename-follow", project: project)
            let chosen = try await builder.createNetwork(name: "net-rename-chosen", project: project)
            try await chosen.replacing(
                domainName: .some("chosen.example")
            ).save(on: app.testPostgres)
            let zone = try await createZone(app: app, token: token, project: project)

            for networkID in [try following.requireID(), try chosen.requireID()] {
                try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        AttachDNSZoneRequest(networkId: networkID, primary: true))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }

            try await app.test(.PUT, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateDNSZoneRequest(name: "renamed.internal"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let renamed = try res.content.decode(DNSZoneResponse.self)
                #expect(renamed.name == "renamed.internal")
            }

            let moved = try #require(try await LogicalNetwork.find(following.id, on: app.testPostgres))
            let untouched = try #require(try await LogicalNetwork.find(chosen.id, on: app.testPostgres))
            #expect(moved.domainName == "renamed.internal")
            #expect(untouched.domainName == "chosen.example")

            // The new spelling still follows: demotion recognizes and clears
            // it instead of treating a stale old name as operator-authored.
            try await app.test(.PUT, "/api/networks/\(try moved.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(clearPrimaryDnsZone: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let cleared = try res.content.decode(NetworkResponse.self)
                #expect(cleared.domainName == nil)
            }
        }
    }

    @Test("A domain name sent alongside the primary zone wins over the derived one")
    func explicitDomainNameInTheSameRequestWins() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-both", project: project)
            let networkID = try network.requireID()
            let zone = try await createZone(app: app, token: token, project: project)
            try await DNSZoneNetworkStore.attach(zoneID: zone.id, networkID: networkID, on: app.testPostgres)

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateNetworkRequest(domainName: "explicit.example", primaryDnsZoneId: zone.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(NetworkResponse.self)
                #expect(updated.primaryDnsZoneId == zone.id)
                #expect(updated.domainName == "explicit.example")
            }
        }
    }

    @Test("The attach response says when guests will not reach the zone")
    func attachResponseCarriesTheDeliveryWarning() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-warn", project: project)
            let networkID = try network.requireID()
            // A network created through the API always has an address; this one
            // is built directly, so give it the one the resolver would have.
            try await network.replacing(resolverIndex: .some(300)).save(on: app.testPostgres)
            let zone = try await createZone(app: app, token: token, project: project)

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let attached = try res.content.decode(DNSZoneResponse.self)
                #expect(attached.networks[0].zoneResolutionWarning == nil)
            }

            // Turning the resolver off is what makes the realized zone inert:
            // guests go back to being handed `dnsServers`, which knows nothing
            // about it.
            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(resolverEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(NetworkResponse.self)
                let warning = try #require(updated.zoneResolutionWarning)
                #expect(warning.contains("resolver is off"))
            }

            try await app.test(.GET, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let fetched = try res.content.decode(DNSZoneResponse.self)
                #expect(fetched.networks[0].zoneResolutionWarning != nil)
            }
        }
    }

    // MARK: - Records

    @Test("Record values are validated and canonicalized per type")
    func recordValueValidation() throws {
        let v4 = try DNSZoneService.validatedValue("192.0.2.5", type: .a)
        #expect(v4 == "192.0.2.5")
        #expect(throws: (any Error).self) { try DNSZoneService.validatedValue("not-an-ip", type: .a) }
        // Swift's integer parsing accepts leading zeros and a leading `+`, so
        // without canonicalization these would be three storable rows for one
        // address — and three A values on the wire for one name.
        let paddedV4 = try DNSZoneService.validatedValue("010.0.0.1", type: .a)
        #expect(paddedV4 == "10.0.0.1")
        let signedV4 = try DNSZoneService.validatedValue("+10.0.0.1", type: .a)
        #expect(signedV4 == "10.0.0.1")
        // Canonicalized so the uniqueness index means what it says.
        let v6 = try DNSZoneService.validatedValue("2001:0DB8::0001", type: .aaaa)
        #expect(v6 == "2001:db8::1")
        let target = try DNSZoneService.validatedValue("Target.Example.COM.", type: .cname)
        #expect(target == "target.example.com")
        let srv = try DNSZoneService.validatedValue(" 10  5 443 svc.acme.internal ", type: .srv)
        #expect(srv == "10 5 443 svc.acme.internal")
        #expect(throws: (any Error).self) { try DNSZoneService.validatedValue("10 5 443", type: .srv) }
        #expect(throws: (any Error).self) { try DNSZoneService.validatedValue("10 5 99999 a.b", type: .srv) }
        #expect(throws: (any Error).self) {
            try DNSZoneService.validatedValue(String(repeating: "x", count: 256), type: .txt)
        }
    }

    @Test("Record CRUD, defaults, and the apex")
    func recordCRUD() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let zone = try await createZone(app: app, token: token, project: project)

            var record: DNSRecordResponse?
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.10"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                record = try res.content.decode(DNSRecordResponse.self)
            }
            let created = try #require(record)
            #expect(created.fqdn == "www.acme.internal")
            #expect(created.ttl == DNSRecord.defaultTTL)
            #expect(created.view == .both)

            // Omitting the name means the apex.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSRecordRequest(type: .txt, value: "v=spf1 -all"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let apex = try res.content.decode(DNSRecordResponse.self)
                #expect(apex.name == "@")
                #expect(apex.fqdn == "acme.internal")
            }

            // Same name+type with a different value is a legal RRset member…
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.11"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            // …but the same value twice is not.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.11"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.PUT, "/api/dns-zones/\(zone.id)/records/\(created.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateDNSRecordRequest(value: "192.0.2.99", ttl: 60, view: .internal))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(DNSRecordResponse.self)
                #expect(updated.value == "192.0.2.99")
                #expect(updated.ttl == 60)
                #expect(updated.view == .internal)
            }

            try await app.test(.DELETE, "/api/dns-zones/\(zone.id)/records/\(created.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("An RRset shares one TTL and view, on write and through the assembler")
    func rrsetSettingsAreUniform() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.10", ttl: 120))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // A second value at the same name and type joins the RRset, so a
            // disagreeing TTL is refused rather than stored — RFC 2181 §5.2,
            // and neither planned driver could express two TTLs at one name.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.11", ttl: 900))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // A disagreeing view is refused for the same reason.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(
                        name: "www", type: .a, value: "192.0.2.11", ttl: 120, view: .internal))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            var secondID: UUID?
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "www", type: .a, value: "192.0.2.11", ttl: 120))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(DNSRecordResponse.self)
                secondID = created.id
            }

            // The set is one assembled entry, not one per member.
            var assembled = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            let entries = assembled.records.filter { $0.name == "www.acme.internal" && $0.type == .a }
            #expect(entries.count == 1)
            #expect(entries.first?.values == ["192.0.2.10", "192.0.2.11"])
            #expect(entries.first?.ttl == 120)

            // Editing the TTL of one member moves the whole set — the
            // alternative would leave a multi-value RRset's TTL uneditable.
            try await app.test(.PUT, "/api/dns-zones/\(zone.id)/records/\(try #require(secondID))") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateDNSRecordRequest(ttl: 60))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let ttls = try await LegacyDNSRecordStore.records(
                zoneID: zone.id, name: "www", on: app.testPostgres).map(\.ttl)
            #expect(ttls == [60, 60])
            assembled = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            #expect(assembled.records.first { $0.name == "www.acme.internal" }?.ttl == 60)
        }
    }

    @Test("Assembly is byte-stable across repeated runs, so phase 3 can hash it")
    func assemblyOrderingIsDeterministic() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-order", project: project)
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))
            try await DNSZoneNetworkStore.attach(
                zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            for index in 0..<6 {
                try await createVM(
                    app: app, project: project, network: network, hostname: "host-\(index)",
                    addresses: [("192.168.1.\(100 + index)", .ipv4, 24)])
                try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateDNSRecordRequest(
                            name: "svc-\(index)", type: .txt, value: "v\(index)", ttl: 60 + index))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }

            // Dictionary iteration order varies run to run and `sort` is not
            // stable, so identical data must still serialize identically —
            // otherwise phase 3 hashes a spurious OVN rewrite.
            let first = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            for _ in 0..<5 {
                let again = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
                #expect(again.records == first.records)
            }
        }
    }

    @Test("A CNAME cannot share an owner name with other data, in either direction")
    func cnameExclusivity() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let zone = try await createZone(app: app, token: token, project: project)

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSRecordRequest(name: "api", type: .a, value: "192.0.2.7"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "api", type: .cname, value: "elsewhere.example.com"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "alias", type: .cname, value: "target.example.com"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSRecordRequest(name: "alias", type: .txt, value: "hi"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("An authored record colliding with a derived one is rejected at write time")
    func authoredDerivedCollisionRejected() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-c", project: project)
            let zone = try await createZone(app: app, token: token, project: project)
            let networkID = try network.requireID()
            try await DNSZoneNetworkStore.attach(zoneID: zone.id, networkID: networkID, on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            try await createVM(
                app: app, project: project, network: network, hostname: "web",
                addresses: [("192.168.1.20", .ipv4, 24)])

            // Same name and type as the derived A record: rejected, not shadowed.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSRecordRequest(name: "web", type: .a, value: "192.0.2.1"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // A CNAME there is refused too — it may hold no other data.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "web", type: .cname, value: "other.example.com"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // A different name is fine.
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSRecordRequest(name: "db", type: .a, value: "192.0.2.1"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    // MARK: - Assembly

    @Test("The assembler produces derived ∪ authored, with A/AAAA/PTR for every VM address")
    func assemblesDerivedAndAuthored() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(
                name: "net-d", project: project, subnet6: "fd00:1::/64", gateway6: "fd00:1::1")
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))
            let networkID = try network.requireID()
            try await DNSZoneNetworkStore.attach(zoneID: zone.id, networkID: networkID, on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            try await createVM(
                app: app, project: project, network: network, hostname: "web",
                addresses: [("192.168.1.20", .ipv4, 24), ("fd00:1::20", .ipv6, 64)])
            // A VM on a network with no primary zone contributes nothing.
            let otherNetwork = try await builder.createNetwork(name: "net-e", project: project)
            try await createVM(
                app: app, project: project, network: otherNetwork, hostname: "hidden",
                addresses: [("192.168.1.30", .ipv4, 24)])

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateDNSRecordRequest(name: "mail", type: .cname, value: "web.acme.internal", ttl: 60))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let assembled = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            #expect(assembled.zoneName == "acme.internal")

            let forwardA = assembled.records.first { $0.name == "web.acme.internal" && $0.type == .a }
            #expect(forwardA?.values == ["192.168.1.20"])
            #expect(forwardA?.origin == .derived)
            let forwardAAAA = assembled.records.first { $0.name == "web.acme.internal" && $0.type == .aaaa }
            #expect(forwardAAAA?.values == ["fd00:1::20"])

            let ptr4 = assembled.records.first { $0.name == "20.1.168.192.in-addr.arpa" }
            #expect(ptr4?.type == .ptr)
            #expect(ptr4?.values == ["web.acme.internal"])
            #expect(assembled.records.contains { $0.type == .ptr && $0.name.hasSuffix(".ip6.arpa") })

            let authored = assembled.records.first { $0.name == "mail.acme.internal" }
            #expect(authored?.type == .cname)
            #expect(authored?.ttl == 60)
            #expect(authored?.origin == .authored)

            // The VM on the unregistered network is absent.
            #expect(!assembled.records.contains { $0.name.hasPrefix("hidden.") })

            // Deterministic ordering, so callers can diff two assemblies.
            let keys = assembled.records.map { "\($0.name)|\($0.type.rawValue)" }
            #expect(keys == keys.sorted())
        }
    }

    @Test("A multi-homed VM publishes every NIC's address under one name")
    func multiHomedVMMergesAddresses() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))

            var networks: [LogicalNetwork] = []
            for (index, subnet) in ["10.10.0.0/24", "10.20.0.0/24"].enumerated() {
                let network = try await builder.createNetwork(
                    name: "multi-\(index)", project: project, subnet: subnet,
                    gateway: subnet.replacingOccurrences(of: ".0/24", with: ".1"))
                try await DNSZoneNetworkStore.attach(
                    zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
                let primaryNetwork = network.replacing(primaryDNSZoneID: .some(zone.id))
                try await primaryNetwork.save(on: app.testPostgres)
                networks.append(primaryNetwork)
            }

            var vm = try await createVM(
                app: app, project: project, network: networks[0], hostname: "multi",
                addresses: [("10.10.0.5", .ipv4, 24)])
            let secondNIC = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try networks[1].requireID(),
                macAddress: VMNetworkInterface.generateMACAddress(),
                deviceName: "net1", orderIndex: 1)
            try await secondNIC.save(on: app.testPostgres)
            try await LegacyInterfaceAddressStore.insert(
                kind: .vm,
                interfaceID: try secondNIC.requireID(),
                logicalNetworkID: try networks[1].requireID(),
                family: .ipv4, address: "10.20.0.5", prefixLength: 24,
                on: app.testPostgres)

            let assembled = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            let forward = assembled.records.first { $0.name == "multi.acme.internal" && $0.type == .a }
            #expect(forward?.values == ["10.10.0.5", "10.20.0.5"])
        }
    }

    @Test("A VM with no hostname contributes nothing rather than falling back to a slug")
    func vmWithoutHostnameIsInvisible() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-f", project: project)
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))
            try await DNSZoneNetworkStore.attach(
                zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            var vm = try await createVM(
                app: app, project: project, network: network, hostname: "nameless",
                addresses: [("192.168.1.40", .ipv4, 24)])
            vm.hostname = nil
            try await vm.save(on: app.testPostgres)

            let assembled = try await DNSZoneAssembler.assemble(zone: zone, on: app.testPostgres)
            #expect(assembled.records.isEmpty)
        }
    }

    @Test("The recordset endpoint serves the same assembled view")
    func recordSetEndpoint() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-g", project: project)
            let zone = try await createZone(app: app, token: token, project: project)
            try await DNSZoneNetworkStore.attach(
                zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)
            try await createVM(
                app: app, project: project, network: network, hostname: "api",
                addresses: [("192.168.1.50", .ipv4, 24)])

            try await app.test(.GET, "/api/dns-zones/\(zone.id)/recordset") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let assembled = try res.content.decode(AssembledDNSZone.self)
                #expect(
                    assembled.records.contains {
                        $0.name == "api.acme.internal" && $0.type == .a && $0.values == ["192.168.1.50"]
                    })
            }
        }
    }

    // MARK: - Hostnames

    @Test("VM create defaults the hostname from a slug and disambiguates duplicates")
    func vmCreateAssignsHostname() async throws {
        try await withDNSTestApp { app, user, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-h", project: project)
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))
            try await DNSZoneNetworkStore.attach(
                zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            let image = try await builder.createImage(name: "dns-image", project: project, uploadedBy: user)
            func createVMOverAPI(named name: String) async throws -> UUID {
                var operationID: UUID?
                try await app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode([
                        "name": name,
                        "imageId": try image.requireID().uuidString,
                        "projectId": project.id!.uuidString,
                        "networkId": try network.requireID().uuidString,
                    ])
                } afterResponse: { res in
                    #expect(res.status == .accepted)
                    let body = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                    operationID = body.resource.id
                }
                return try #require(operationID)
            }

            let firstID = try await createVMOverAPI(named: "Web Server")
            let first = try #require(try await VM.find(firstID, on: app.testPostgres))
            #expect(first.hostname == "web-server")

            // An ordinary duplicate name must not fail the create.
            let secondID = try await createVMOverAPI(named: "Web Server")
            let second = try #require(try await VM.find(secondID, on: app.testPostgres))
            #expect(second.hostname == "web-server-2")
        }
    }

    @Test("An explicit hostname is held to strict uniqueness within its zones")
    func explicitHostnameConflicts() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-i", project: project)
            let zoneResponse = try await createZone(app: app, token: token, project: project)
            let zone = try #require(try await LegacyDNSZoneStore.find(id: zoneResponse.id, on: app.testPostgres))
            try await DNSZoneNetworkStore.attach(
                zoneID: zone.id, networkID: try network.requireID(), on: app.testPostgres)
            try await network.replacing(primaryDNSZoneID: .some(zone.id)).save(on: app.testPostgres)

            let existing = try await createVM(
                app: app, project: project, network: network, hostname: "taken",
                addresses: [("192.168.1.60", .ipv4, 24)])
            let other = try await createVM(
                app: app, project: project, network: network, hostname: "free",
                addresses: [("192.168.1.61", .ipv4, 24)])

            try await app.test(.PUT, "/api/vms/\(try other.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["hostname": "taken"])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // Renaming to a free label works, and doesn't disturb the other VM.
            try await app.test(.PUT, "/api/vms/\(try other.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["hostname": "Renamed"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let renamed = try res.content.decode(VMDetailResponse.self)
                #expect(renamed.hostname == "renamed")
            }
            let reloaded = try #require(try await VM.find(try existing.requireID(), on: app.testPostgres))
            #expect(reloaded.hostname == "taken")
        }
    }

    @Test("Making a zone primary is refused when the VMs already on the network would collide")
    func primaryAssignmentRejectsExistingCollisions() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let network = try await builder.createNetwork(name: "net-j", project: project)
            let zone = try await createZone(app: app, token: token, project: project)
            let networkID = try network.requireID()

            // Two VMs sharing a hostname — possible while nothing registers.
            try await createVM(
                app: app, project: project, network: network, hostname: "dup",
                addresses: [("192.168.1.70", .ipv4, 24)])
            try await createVM(
                app: app, project: project, network: network, hostname: "dup",
                addresses: [("192.168.1.71", .ipv4, 24)])

            try await app.test(.POST, "/api/dns-zones/\(zone.id)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // Nothing was written: a request that asks for `primary` and can't
            // have it leaves no half-applied attachment behind.
            let reloaded = try #require(try await LogicalNetwork.find(networkID, on: app.testPostgres))
            #expect(reloaded.primaryDNSZoneID == nil)
            let attachments = try await DNSZoneNetworkStore.count(on: app.testPostgres)
            #expect(attachments == 0)
        }
    }

    // MARK: - Authorization

    @Test("Zones and records are default-deny for a caller with no access")
    func authorizationIsEnforced() async throws {
        try await withDNSTestApp { app, _, _, project, token in
            let zone = try await createZone(app: app, token: token, project: project)

            let builder = TestDataBuilder(db: app.testPostgres)
            let outsider = try await builder.createUser(
                username: "outsider", email: "out@example.com", displayName: "Outsider")
            let outsiderOrg = try await builder.createOrganization(name: "Outsider Org")
            try await builder.addUserToOrganization(
                user: outsider, organization: outsiderOrg, role: "member")
            try await outsider.replacingCurrentOrganization(outsiderOrg.id).save(on: app.testPostgres)
            let outsiderToken = try await outsider.generateAPIKey(on: app)

            try await app.test(.GET, "/api/dns-zones/\(zone.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.POST, "/api/dns-zones/\(zone.id)/records") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(CreateDNSRecordRequest(name: "x", type: .a, value: "192.0.2.1"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            // And the zone is not visible in their list.
            try await app.test(.GET, "/api/dns-zones") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<DNSZoneResponse>.self)
                #expect(page.items.isEmpty)
            }
        }
    }

    @Test("dns_zone and dns_record are wired into the Cedar vocabulary")
    func cedarVocabulary() {
        #expect(IAMNodeType(rawValue: "dns_zone") == .dnsZone)
        #expect(IAMNodeType(rawValue: "dns_record") == .dnsRecord)
        #expect(IAMNodeType.dnsZone.cedarEntityType == .dnsZone)
        #expect(IAMRoleRegistry.allActions.contains("dns:read"))
        #expect(IAMRoleRegistry.allActions.contains("dns:attach"))
        #expect(IAMRoleRegistry.actions(for: .viewer).contains("dns:list"))
        #expect(!IAMRoleRegistry.actions(for: .viewer).contains("dns:create"))
        #expect(IAMRoleRegistry.actions(for: .editor).contains("dns:delete"))

        // A record is reachable through its zone, and a zone through its project.
        #expect(CedarSchemaBuilder.resourceTypes(for: "dns:read").contains(.dnsRecord))
        #expect(CedarSchemaBuilder.descendantTypes(of: .dnsZone).contains(.dnsRecord))
        #expect(CedarSchemaBuilder.descendantTypes(of: .project).contains(.dnsRecord))

        #expect(CedarSchemaBuilder.resourceTypes(for: "dns:attach").contains(.dnsZone))
    }
}
