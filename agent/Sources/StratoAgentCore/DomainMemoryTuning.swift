import Foundation

/// Converges only `<memtune><hard_limit>` in a persistent libvirt definition.
/// Every unrelated child survives so an operator's soft limit, swap limit, or
/// namespace extension is not erased by a boot-time safety update.
public enum DomainMemoryTuning {
    public static func updatingHardLimit(
        in xml: String, bytes: Int64?
    ) throws -> String? {
        var domain = try DomainXMLNode.parse(xml)
        guard domain.name == "domain" else {
            throw DomainInventoryError.unparseable("the document root is <\(domain.name)>, not <domain>")
        }

        let desired = bytes.map { String(QEMUMemoryCeiling.kibibytes(guestMemoryBytes: $0, overheadBytes: 0)) }
        if let memtuneIndex = domain.firstIndex(ofChildNamed: "memtune") {
            var memtune = domain.children[memtuneIndex]
            guard memtune.text == nil else {
                throw DomainInventoryError.unparseable("<memtune> contains text rather than tuning elements")
            }
            let current = memtune.child(named: "hard_limit")
            if let desired,
                current?.attribute("unit") == "KiB", current?.text == desired
            {
                return nil
            }

            memtune.removeChildren(named: "hard_limit")
            if let desired {
                memtune.insert(
                    DomainXMLNode("hard_limit", [("unit", "KiB")], text: desired), at: 0)
            }
            domain.editChild(named: "memtune") { $0 = memtune }
            if memtune.children.isEmpty { domain.removeChildren(named: "memtune") }
            return domain.render()
        }

        guard let desired else { return nil }
        let memtune = DomainXMLBuilder.memoryHardLimitNode(kibibytes: desired)
        if let vcpuIndex = domain.firstIndex(ofChildNamed: "vcpu") {
            domain.insert(memtune, at: vcpuIndex)
        } else {
            domain.append(memtune)
        }
        return domain.render()
    }
}
