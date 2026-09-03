import StratoShared

/// Preserves the desired volume order while one realized attachment is
/// recorded into a VM manifest.
public enum ManifestVolumeOrder {
    public static func recording(
        _ update: VolumeSpec,
        in recorded: [VolumeSpec],
        authoritative: [VolumeSpec]?
    ) -> (volumes: [VolumeSpec], orderedBootVolumeIds: [String]) {
        var remaining = Dictionary(
            recorded.map { ($0.volumeId, $0) },
            uniquingKeysWith: { first, _ in first })
        remaining[update.volumeId] = update

        var volumes: [VolumeSpec] = []
        for desired in authoritative ?? [] {
            if let realized = remaining.removeValue(forKey: desired.volumeId) {
                volumes.append(realized)
            }
        }
        for existing in recorded {
            if let retained = remaining.removeValue(forKey: existing.volumeId) {
                volumes.append(retained)
            }
        }
        if let appended = remaining.removeValue(forKey: update.volumeId) {
            volumes.append(appended)
        }

        let recordedIds = Set(volumes.map(\.volumeId))
        let orderedBootVolumeIds: [String] = (authoritative ?? volumes).compactMap { volume in
            guard volume.bootOrder != nil, recordedIds.contains(volume.volumeId) else { return nil }
            return volume.volumeId.uuidString
        }
        return (volumes, orderedBootVolumeIds)
    }
}
