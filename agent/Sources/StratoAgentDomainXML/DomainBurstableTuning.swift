import Foundation
import StratoAgentKit
import StratoShared

/// Plans supported libvirt controls. Callers must persist this definition
/// before boot and separately apply/read back live controls for adoption.
/// Nothing here discovers or writes libvirt-owned cgroup descendants.
public enum DomainBurstableTuning {
    public static func updating(
        in xml: String, limits: BurstableResourceLimits, pageSize: Int64,
        resourceClass: WorkloadResourceClassSnapshot? = nil, guestGrantBytes: Int64? = nil
    ) throws -> String? {
        var domain = try DomainXMLNode.parse(xml)
        guard domain.name == "domain" else {
            throw DomainInventoryError.unparseable("the document root is <\(domain.name)>, not <domain>")
        }
        for container in ["memtune", "cputune"] {
            guard domain.children.filter({ $0.name == container }).count <= 1,
                domain.child(named: container)?.text == nil
            else {
                throw DomainInventoryError.unparseable("<\(container)> is duplicated or contains text")
            }
        }
        let original = domain
        var cputune = domain.child(named: "cputune") ?? DomainXMLNode("cputune")
        // A positive quota on any QEMU thread group conflicts with shared
        // fair-share behavior. Preserve the definition and reject it instead
        // of silently discarding an operator's bandwidth policy.
        for quota in cputune.children
        where ["quota", "global_quota", "emulator_quota", "iothread_quota"].contains(quota.name) {
            guard let value = quota.text.flatMap(Int64.init), value <= 0 else {
                throw DomainInventoryError.unparseable("<\(quota.name)> conflicts with burstable CPU sharing")
            }
        }
        let memory = try limits.libvirtMemoryKibibytes(pageSize: pageSize)
        var memtune = domain.child(named: "memtune") ?? DomainXMLNode("memtune")
        set(&memtune, name: "hard_limit", value: String(memory.maximum), unit: "KiB")
        set(&memtune, name: "soft_limit", value: String(memory.high), unit: "KiB")
        set(&cputune, name: "shares", value: String(limits.cpuWeight))
        if domain.child(named: "memtune") != nil {
            domain.editChild(named: "memtune") { $0 = memtune }
        } else {
            domain.insert(memtune, at: domain.firstIndex(ofChildNamed: "vcpu") ?? domain.children.count)
        }
        if domain.child(named: "cputune") != nil {
            domain.editChild(named: "cputune") { $0 = cputune }
        } else if let vcpu = domain.firstIndex(ofChildNamed: "vcpu") {
            domain.insert(cputune, at: vcpu + 1)
        } else {
            domain.append(cputune)
        }
        if let resourceClass {
            _ = try Self.resourceClass(in: xml)
            guard resourceClass.policy.kind == .burstable, limits.cpuWeight == resourceClass.policy.cpuWeight,
                domain.children.filter({ $0.name == "metadata" }).count <= 1,
                domain.child(named: "metadata")?.text == nil
            else { throw DomainInventoryError.unparseable("Invalid burstable runtime metadata") }
            var metadata = domain.child(named: "metadata") ?? DomainXMLNode("metadata")
            // Persist the canonical admitted snapshot, not a second policy
            // model. Unrelated application metadata remains unchanged.
            let encoder = WireProtocol.makeEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(resourceClass).base64EncodedString()
            let effectiveGrant = try guestGrantBytes ?? acknowledgedGuestGrant(in: xml)
            if let effectiveGrant, effectiveGrant <= 0 {
                throw DomainInventoryError.unparseable("Invalid admitted guest grant")
            }
            if let effectiveGrant {
                let overhead = limits.memoryMaxBytes - effectiveGrant
                guard overhead >= 0,
                    try resourceClass.policy.runtimeLimits(guestBytes: effectiveGrant, backendOverheadBytes: overhead)
                        == limits.desired
                else { throw DomainInventoryError.unparseable("Admitted class does not match runtime controls") }
            }
            metadata.removeChildren(named: "stratoResourceClass")
            metadata.append(
                DomainXMLNode(
                    "stratoResourceClass",
                    [("guestBytes", effectiveGrant.map(String.init)), ("xmlns", metadataNamespace)], text: encoded))
            if domain.child(named: "metadata") == nil {
                domain.insert(metadata, at: 0)
            } else {
                domain.editChild(named: "metadata") { $0 = metadata }
            }
        }
        return domain == original ? nil : domain.render()
    }

    private static let metadataNamespace = "urn:strato:runtime:resource-class:1"

    public static func resourceClass(in xml: String) throws -> WorkloadResourceClassSnapshot? {
        let domain = try DomainXMLNode.parse(xml)
        guard domain.name == "domain", domain.children.filter({ $0.name == "metadata" }).count <= 1 else {
            throw DomainInventoryError.unparseable("Ambiguous domain runtime metadata")
        }
        let entries = domain.child(named: "metadata")?.children.filter { $0.name == "stratoResourceClass" } ?? []
        guard entries.count <= 1 else { throw DomainInventoryError.unparseable("Duplicated admitted resource class") }
        guard let entry = entries.first else { return nil }
        guard entry.attribute("xmlns") == metadataNamespace, let raw = entry.text,
            let data = Data(base64Encoded: raw)
        else { throw DomainInventoryError.unparseable("Malformed admitted resource class metadata") }
        return try WireProtocol.makeDecoder().decode(WorkloadResourceClassSnapshot.self, from: data)
    }

    /// Last acknowledged control grant survives a partial guest resize so
    /// the next retry can recognize old/target controller phase values.
    public static func acknowledgedGuestGrant(in xml: String) throws -> Int64? {
        _ = try resourceClass(in: xml)
        let node = try DomainXMLNode.parse(xml).child(named: "metadata")?.child(named: "stratoResourceClass")
        guard let raw = node?.attribute("guestBytes") else { return nil }
        guard let bytes = Int64(raw), bytes > 0 else {
            throw DomainInventoryError.unparseable("Invalid admitted guest grant")
        }
        return bytes
    }

    public static func snapshotDomainXML(in xml: String) throws -> String {
        let snapshot = try DomainXMLNode.parse(xml)
        guard snapshot.name == "domainsnapshot", snapshot.children.filter({ $0.name == "domain" }).count == 1,
            let domain = snapshot.child(named: "domain")
        else { throw DomainInventoryError.unparseable("Checkpoint has no unambiguous domain definition") }
        return domain.render()
    }

    private static func set(_ container: inout DomainXMLNode, name: String, value: String, unit: String? = nil) {
        let index = container.firstIndex(ofChildNamed: name) ?? container.children.count
        let attributes = unit.map { [("unit", $0)] } ?? []
        let desired = DomainXMLNode(name, attributes, text: value)
        let existing = container.children.filter { $0.name == name }
        guard existing != [desired] else { return }
        container.removeChildren(named: name)
        container.insert(desired, at: min(index, container.children.count))
    }
}
