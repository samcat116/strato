import Foundation
import StratoAgentKit

/// Plans supported libvirt controls. Callers must persist this definition
/// before boot and separately apply/read back live controls for adoption.
/// Nothing here discovers or writes libvirt-owned cgroup descendants.
public enum DomainBurstableTuning {
    public static func updating(in xml: String, limits: BurstableResourceLimits) throws -> String? {
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
        let memory = try limits.libvirtMemoryKibibytes()
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
        return domain == original ? nil : domain.render()
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
