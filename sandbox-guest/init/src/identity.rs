//! Filesystem identity helpers used when a checkpoint becomes a new sandbox.
//! Kept outside the Linux vsock module so path behavior is unit-testable on
//! every development host.

use std::path::Path;

/// Rotate existing machine-id files without manufacturing them in images that
/// intentionally omit machine identity (scratch/distroless images). Missing
/// files and parents are therefore a successful no-op; failures writing a file
/// that does exist remain fatal.
pub fn reset_machine_id_files(
    entropy: &[u8],
    machine_id_path: &Path,
    dbus_machine_id_path: &Path,
) -> Result<(), String> {
    let identity_entropy = entropy
        .get(..16)
        .ok_or_else(|| "at least 16 bytes are required to rotate machine-id".to_string())?;
    let machine_id = identity_entropy
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let contents = format!("{machine_id}\n");

    if machine_id_path.exists() {
        std::fs::write(machine_id_path, &contents)
            .map_err(|e| format!("write {}: {e}", machine_id_path.display()))?;
    }
    if dbus_machine_id_path.exists() && !dbus_machine_id_path.is_symlink() {
        std::fs::write(dbus_machine_id_path, &contents)
            .map_err(|e| format!("write {}: {e}", dbus_machine_id_path.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn test_root(name: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "strato-identity-{name}-{}-{nonce}",
            std::process::id()
        ))
    }

    #[test]
    fn missing_machine_id_paths_are_a_noop() {
        let root = test_root("missing");
        let machine_id = root.join("etc/machine-id");
        let dbus = root.join("var/lib/dbus/machine-id");

        reset_machine_id_files(&[7; 32], &machine_id, &dbus).expect("missing paths are valid");

        assert!(!root.exists(), "the helper must not manufacture /etc");
    }

    #[test]
    fn existing_machine_id_files_are_rotated() {
        let root = test_root("existing");
        let machine_id = root.join("etc/machine-id");
        let dbus = root.join("var/lib/dbus/machine-id");
        std::fs::create_dir_all(machine_id.parent().expect("machine-id parent"))
            .expect("create etc");
        std::fs::create_dir_all(dbus.parent().expect("dbus parent")).expect("create dbus");
        std::fs::write(&machine_id, "old\n").expect("seed machine-id");
        std::fs::write(&dbus, "old\n").expect("seed dbus machine-id");

        reset_machine_id_files(&[0xab; 32], &machine_id, &dbus).expect("rotate machine ids");

        let expected = format!("{}\n", "ab".repeat(16));
        assert_eq!(std::fs::read_to_string(&machine_id).unwrap(), expected);
        assert_eq!(std::fs::read_to_string(&dbus).unwrap(), expected);
        std::fs::remove_dir_all(root).expect("remove test directory");
    }
}
