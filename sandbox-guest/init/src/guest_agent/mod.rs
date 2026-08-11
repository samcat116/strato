//! Lifecycle and identity for the VM guest-agent service.

mod exec;
mod vsock;

use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use strato_sandbox_init::protocol::MAX_IDENTITY_BYTES;

const MACHINE_ID_PATH: &str = "/etc/machine-id";
const BOOT_ID_PATH: &str = "/proc/sys/kernel/random/boot_id";

/// Identity echoed over the historical `sandbox_id` + `nonce` wire fields.
///
/// The machine id distinguishes the installed guest OS. Linux's boot id is the
/// generation nonce: it changes on a VM reboot but remains stable when systemd
/// restarts only this service, so a restart can rebind the listener without
/// making one boot look like a different guest generation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GuestIdentity {
    pub guest_id: String,
    pub nonce: String,
}

impl GuestIdentity {
    fn load() -> Result<Self, String> {
        Self::load_from(Path::new(MACHINE_ID_PATH), Path::new(BOOT_ID_PATH))
    }

    fn load_from(machine_id_path: &Path, boot_id_path: &Path) -> Result<Self, String> {
        let machine_id = std::fs::read_to_string(machine_id_path)
            .map_err(|e| format!("read {}: {e}", machine_id_path.display()))?;
        let boot_id = std::fs::read_to_string(boot_id_path)
            .map_err(|e| format!("read {}: {e}", boot_id_path.display()))?;
        Self::from_contents(&machine_id, &boot_id)
    }

    fn from_contents(machine_id: &str, boot_id: &str) -> Result<Self, String> {
        Ok(Self {
            guest_id: validate_id("machine id", machine_id)?,
            nonce: validate_id("boot id", boot_id)?,
        })
    }
}

fn validate_id(name: &str, value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() {
        return Err(format!("{name} is empty"));
    }
    if value.len() > MAX_IDENTITY_BYTES {
        return Err(format!(
            "{name} exceeds the {MAX_IDENTITY_BYTES}-byte protocol limit"
        ));
    }
    Ok(value.to_string())
}

pub fn run() -> ExitCode {
    let identity = match GuestIdentity::load() {
        Ok(identity) => Arc::new(identity),
        Err(e) => {
            eprintln!("[strato-guest-agent] identity: {e}");
            return ExitCode::FAILURE;
        }
    };

    eprintln!(
        "[strato-guest-agent] starting for machine {} (boot {})",
        identity.guest_id, identity.nonce
    );
    match vsock::serve(identity) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("[strato-guest-agent] {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_uses_trimmed_machine_and_boot_ids() {
        let identity = GuestIdentity::from_contents("machine-1\n", "boot-1\n").expect("identity");
        assert_eq!(
            identity,
            GuestIdentity {
                guest_id: "machine-1".into(),
                nonce: "boot-1".into(),
            }
        );
    }

    #[test]
    fn identity_refuses_empty_or_host_rejected_values() {
        assert!(GuestIdentity::from_contents("\n", "boot").is_err());
        assert!(GuestIdentity::from_contents("machine", " \n").is_err());
        let too_long = "x".repeat(MAX_IDENTITY_BYTES + 1);
        assert!(GuestIdentity::from_contents(&too_long, "boot").is_err());
        assert!(GuestIdentity::from_contents("machine", &too_long).is_err());
    }
}
