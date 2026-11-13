import Foundation
import SwiftProtobuf

extension Strato_Agent_V1_BootSource: Codable {
    private enum CodingKeys: String, CodingKey { case disk, directKernel }
    private struct DiskJSON: Codable { let firmware: String? }
    private struct KernelJSON: Codable { let kernel: String; let initramfs: String?; let cmdline: String? }
    public static func disk(firmware: String?) -> Self {
        .with { $0.value = .disk(.with { if let firmware { $0.firmware = firmware } }) }
    }
    public static func directKernel(kernel: String, initramfs: String?, cmdline: String?) -> Self {
        .with {
            $0.value = .directKernel(
                .with {
                    $0.kernel = kernel
                    if let initramfs { $0.initramfs = initramfs }
                    if let cmdline { $0.cmdline = cmdline }
                })
        }
    }
    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one recognized union case"))
        }
        switch c.allKeys[0] {
        case .disk:
            let v = try c.decode(DiskJSON.self, forKey: .disk)
            self = .disk(firmware: v.firmware)
        case .directKernel:
            let v = try c.decode(KernelJSON.self, forKey: .directKernel)
            self = .directKernel(kernel: v.kernel, initramfs: v.initramfs, cmdline: v.cmdline)
        }
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .disk(let v): try c.encode(DiskJSON(firmware: v.hasFirmware ? v.firmware : nil), forKey: .disk)
        case .directKernel(let v):
            try c.encode(
                KernelJSON(
                    kernel: v.kernel, initramfs: v.hasInitramfs ? v.initramfs : nil,
                    cmdline: v.hasCmdline ? v.cmdline : nil), forKey: .directKernel)
        case nil: throw AgentProtocolJSONError.invalidUnion
        }
    }
}

extension Strato_Agent_V1_DesiredVolumeStorage: Codable {
    private enum CodingKeys: String, CodingKey { case local, ceph }
    private struct EmptyJSON: Codable {}
    public static var local: Self { .with { $0.value = .local(.init()) } }
    public static func ceph(_ configuration: CephVolumeStorage) -> Self {
        .with { $0.value = .ceph(.with { $0.configuration = configuration }) }
    }
    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one recognized union case"))
        }
        switch c.allKeys[0] {
        case .local: _ = try c.decode(EmptyJSON.self, forKey: .local); self = .local
        case .ceph: self = .ceph(try c.decode(CephVolumeStorage.self, forKey: .ceph))
        }
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .local: try c.encode(EmptyJSON(), forKey: .local)
        case .ceph(let v): try c.encode(v.configuration, forKey: .ceph)
        case nil: throw AgentProtocolJSONError.invalidUnion
        }
    }
}

extension Strato_Agent_V1_DiskAttachment: Codable {
    private enum CodingKeys: String, CodingKey { case file, blockDevice, rbd }
    private struct FileJSON: Codable { let path: String; let format: DiskFormat }
    private struct BlockJSON: Codable { let path: String }
    private struct RBDJSON: Codable {
        let pool: String; let image: String; let namespace: String; let user: String
        let monEndpoints: [String]; let clusterId: UUID; let credentialId: UUID; let configPath: String
    }
    public static func file(path: String, format: DiskFormat) -> Self {
        .with {
            $0.value = .file(
                .with {
                    $0.path = path; $0.format = format
                })
        }
    }
    public static func blockDevice(path: String) -> Self {
        .with { $0.value = .blockDevice(.with { $0.path = path }) }
    }
    public static func rbd(
        pool: String, image: String, namespace: String, user: String,
        monEndpoints: [String], clusterId: UUID, credentialId: UUID, configPath: String
    ) -> Self {
        .with {
            $0.value = .rbd(
                .with {
                    $0.pool = pool; $0.image = image; $0.namespace = namespace; $0.user = user
                    $0.monEndpoints = .with { $0.values = monEndpoints }
                    $0.clusterID = clusterId.uuidString; $0.credentialID = credentialId.uuidString;
                    $0.configPath = configPath
                })
        }
    }
    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one recognized union case"))
        }
        switch c.allKeys[0] {
        case .file:
            let v = try c.decode(FileJSON.self, forKey: .file); self = .file(path: v.path, format: v.format)
        case .blockDevice:
            let v = try c.decode(BlockJSON.self, forKey: .blockDevice); self = .blockDevice(path: v.path)
        case .rbd:
            let v = try c.decode(RBDJSON.self, forKey: .rbd)
            self = .rbd(
                pool: v.pool, image: v.image, namespace: v.namespace, user: v.user,
                monEndpoints: v.monEndpoints, clusterId: v.clusterId, credentialId: v.credentialId,
                configPath: v.configPath)
        }
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .file(let v): try c.encode(FileJSON(path: v.path, format: v.format), forKey: .file)
        case .blockDevice(let v): try c.encode(BlockJSON(path: v.path), forKey: .blockDevice)
        case .rbd(let v):
            guard let cluster = UUID(uuidString: v.clusterID), let credential = UUID(uuidString: v.credentialID) else {
                throw AgentProtocolJSONError.invalidIdentifier
            }
            try c.encode(
                RBDJSON(
                    pool: v.pool, image: v.image, namespace: v.namespace, user: v.user,
                    monEndpoints: v.monEndpoints.values, clusterId: cluster, credentialId: credential,
                    configPath: v.configPath), forKey: .rbd)
        case nil: throw AgentProtocolJSONError.invalidUnion
        }
    }
}

enum AgentProtocolJSONError: Error { case invalidUnion, invalidIdentifier }
