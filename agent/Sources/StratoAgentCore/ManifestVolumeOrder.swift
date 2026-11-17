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
            recorded.map { ($0.volumeID, $0) },
            uniquingKeysWith: { first, _ in first })
        remaining[update.volumeID] = update

        var volumes: [VolumeSpec] = []
        for desired in authoritative ?? [] {
            if let realized = remaining.removeValue(forKey: desired.volumeID) {
                volumes.append(realized)
            }
        }
        for existing in recorded {
            if let retained = remaining.removeValue(forKey: existing.volumeID) {
                volumes.append(retained)
            }
        }
        if let appended = remaining.removeValue(forKey: update.volumeID) {
            volumes.append(appended)
        }

        let recordedIds = Set(volumes.map(\.volumeID))
        let orderedBootVolumeIds: [String] = (authoritative ?? volumes).compactMap { volume in
            guard volume.hasBootOrder, recordedIds.contains(volume.volumeID) else { return nil }
            return volume.volumeID
        }
        return (volumes, orderedBootVolumeIds)
    }
}
