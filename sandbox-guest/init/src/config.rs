//! The config drive (`/dev/vdb`) — the guest's input contract.
//!
//! Because the v1 vsock surface is health + exit only (issue #419), the
//! workload's launch configuration is delivered out-of-band on a tiny
//! read-only block device the host writes per sandbox, rather than over the
//! control channel. This keeps issue #418's flattened container image pristine
//! (the init is never written into it) and lets the workload launch without
//! waiting for the host to connect vsock.
//!
//! The drive holds a single JSON document ([`GuestConfig`]) containing:
//!   * where the container rootfs is and how to mount it,
//!   * the sandbox's identity and vsock port, and
//!   * the OCI image config **plus** the sandbox's overrides — the guest does
//!     the merge, so OCI runtime semantics live in exactly one place.
//!
//! The host side (issue #421) produces this document; the schema is versioned
//! so the two can evolve in lockstep.

use serde::{Deserialize, Serialize};

/// The current config-drive schema version. The host stamps this; a guest that
/// does not recognize it refuses to launch rather than guessing.
pub const SCHEMA_VERSION: u32 = 1;

/// Top-level config-drive document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuestConfig {
    /// Schema version; must equal [`SCHEMA_VERSION`] for this init build.
    pub schema_version: u32,
    /// The sandbox's control-plane id, echoed back over vsock for identity.
    pub sandbox_id: String,
    /// Opaque per-boot nonce so the host can distinguish a fresh boot from a
    /// resumed snapshot (phase 4, issue #426). Echoed in every vsock response.
    pub identity_nonce: String,
    /// Where and how to mount the container rootfs.
    pub rootfs: RootfsSpec,
    /// Guest vsock port for the control agent.
    #[serde(default = "default_vsock_port")]
    pub vsock_port: u32,
    /// The OCI image's `config` object (the subset the guest applies),
    /// extracted host-side by issue #418.
    #[serde(default)]
    pub image_config: ImageConfig,
    /// The sandbox spec's process overrides (from `SandboxSpec`).
    #[serde(default)]
    pub overrides: ProcessOverrides,
}

fn default_vsock_port() -> u32 {
    crate::protocol::DEFAULT_VSOCK_PORT
}

/// Container rootfs mount instructions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootfsSpec {
    /// Block device the flattened container image is attached as (e.g.
    /// `/dev/vda`).
    pub device: String,
    /// Filesystem type the host formatted it with (issue #418 produces ext4).
    #[serde(default = "default_fstype")]
    pub fstype: String,
    /// Mount read-only. v1 defaults to read-write on the ephemeral flattened
    /// copy, matching container semantics.
    #[serde(default)]
    pub readonly: bool,
}

fn default_fstype() -> String {
    "ext4".to_string()
}

/// The subset of the OCI image `config` the guest applies. Field names match
/// the OCI image-spec JSON (PascalCase) so the host can forward the image's
/// config object with minimal reshaping.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageConfig {
    #[serde(rename = "Env", default)]
    pub env: Vec<String>,
    #[serde(rename = "Entrypoint", default)]
    pub entrypoint: Vec<String>,
    #[serde(rename = "Cmd", default)]
    pub cmd: Vec<String>,
    #[serde(rename = "WorkingDir", default)]
    pub working_dir: String,
    /// OCI `User`: `uid`, `uid:gid`, or a name. v1 resolves numeric forms only.
    #[serde(rename = "User", default)]
    pub user: String,
}

/// Sandbox-level overrides for the image config. A `None`/empty field means
/// "inherit from the image"; a present field replaces the image's value.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessOverrides {
    #[serde(default)]
    pub entrypoint: Option<Vec<String>>,
    #[serde(default)]
    pub cmd: Option<Vec<String>>,
    /// Extra/replacement env vars, applied over the image env (override wins
    /// per key). Kept as a map because that is how `SandboxSpec` models it.
    #[serde(default)]
    pub env: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub workdir: Option<String>,
    #[serde(default)]
    pub user: Option<String>,
}

/// The fully resolved process the init will exec, after merging the image
/// config with the sandbox overrides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedProcess {
    /// Full argv: effective entrypoint followed by effective cmd.
    pub argv: Vec<String>,
    /// Environment as `KEY=VALUE` strings, image env with overrides applied.
    pub env: Vec<String>,
    /// Working directory (defaults to `/` when neither image nor override set
    /// one).
    pub cwd: String,
    /// Numeric uid to run as.
    pub uid: u32,
    /// Numeric gid to run as.
    pub gid: u32,
}

/// Errors resolving the process to exec.
#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    /// The config drive's schema version is not understood by this init.
    UnsupportedSchema(u32),
    /// Neither the image nor the overrides supplied a command to run.
    EmptyCommand,
    /// The `User` field could not be parsed as a numeric `uid[:gid]`.
    InvalidUser(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::UnsupportedSchema(v) => {
                write!(
                    f,
                    "unsupported config-drive schema version {v} (expected {SCHEMA_VERSION})"
                )
            }
            ConfigError::EmptyCommand => {
                write!(
                    f,
                    "no entrypoint or cmd to run (image and overrides are both empty)"
                )
            }
            ConfigError::InvalidUser(u) => {
                write!(f, "cannot parse User '{u}' as numeric uid[:gid]")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

impl GuestConfig {
    /// Parse a config-drive document from its JSON bytes.
    pub fn from_slice(bytes: &[u8]) -> Result<GuestConfig, serde_json::Error> {
        serde_json::from_slice(bytes)
    }

    /// Parse the document read straight off the raw config block device.
    ///
    /// The host writes the JSON document to the start of the device and pads
    /// the remainder to the device size with NUL bytes (there is no filesystem
    /// on the config drive — the guest reads raw bytes). Trailing NULs and
    /// whitespace are stripped before parsing.
    pub fn from_config_drive(bytes: &[u8]) -> Result<GuestConfig, serde_json::Error> {
        let end = bytes
            .iter()
            .rposition(|&b| b != 0 && !b.is_ascii_whitespace())
            .map_or(0, |i| i + 1);
        Self::from_slice(&bytes[..end])
    }

    /// Merge the image config with the overrides into the concrete process to
    /// exec.
    ///
    /// Merge rules (OCI/Docker-compatible):
    ///   * **entrypoint**: `overrides.entrypoint` if present, else the image's.
    ///   * **cmd**: `overrides.cmd` if present. If the entrypoint is overridden
    ///     and no cmd override is given, the image `Cmd` is **cleared** —
    ///     matching `docker run --entrypoint`, where a new entrypoint drops the
    ///     image's default arguments. Otherwise the image `Cmd` is kept.
    ///   * **argv** = effective entrypoint ++ effective cmd; must be non-empty.
    ///   * **env**: image `Env`, then overrides applied (replace on key match,
    ///     append otherwise), key order stable for determinism.
    ///   * **cwd**: `overrides.workdir` ?? image `WorkingDir` ?? `/`.
    ///   * **user**: `overrides.user` ?? image `User` ?? `0:0`, numeric only.
    pub fn resolve_process(&self) -> Result<ResolvedProcess, ConfigError> {
        if self.schema_version != SCHEMA_VERSION {
            return Err(ConfigError::UnsupportedSchema(self.schema_version));
        }

        let entrypoint = self
            .overrides
            .entrypoint
            .clone()
            .unwrap_or_else(|| self.image_config.entrypoint.clone());

        let cmd = match &self.overrides.cmd {
            Some(cmd) => cmd.clone(),
            None => {
                // A new entrypoint with no explicit cmd clears the image cmd.
                if self.overrides.entrypoint.is_some() {
                    Vec::new()
                } else {
                    self.image_config.cmd.clone()
                }
            }
        };

        let mut argv = entrypoint;
        argv.extend(cmd);
        if argv.is_empty() {
            return Err(ConfigError::EmptyCommand);
        }

        let env = merge_env(&self.image_config.env, &self.overrides.env);

        let cwd = self
            .overrides
            .workdir
            .clone()
            .filter(|w| !w.is_empty())
            .or_else(|| {
                if self.image_config.working_dir.is_empty() {
                    None
                } else {
                    Some(self.image_config.working_dir.clone())
                }
            })
            .unwrap_or_else(|| "/".to_string());

        let user_spec = self
            .overrides
            .user
            .clone()
            .filter(|u| !u.is_empty())
            .or_else(|| {
                if self.image_config.user.is_empty() {
                    None
                } else {
                    Some(self.image_config.user.clone())
                }
            })
            .unwrap_or_else(|| "0:0".to_string());
        let (uid, gid) = parse_user(&user_spec)?;

        Ok(ResolvedProcess {
            argv,
            env,
            cwd,
            uid,
            gid,
        })
    }
}

/// Merge image env (`KEY=VALUE` list) with an overrides map. Overrides replace
/// existing keys in place and are otherwise appended in sorted order, so the
/// result is deterministic.
fn merge_env(
    image_env: &[String],
    overrides: &std::collections::BTreeMap<String, String>,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(image_env.len() + overrides.len());
    let mut seen: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();

    for entry in image_env {
        let key = entry.split('=').next().unwrap_or(entry).to_string();
        seen.insert(key, out.len());
        out.push(entry.clone());
    }
    for (key, value) in overrides {
        let entry = format!("{key}={value}");
        if let Some(&idx) = seen.get(key) {
            out[idx] = entry;
        } else {
            seen.insert(key.clone(), out.len());
            out.push(entry);
        }
    }
    out
}

/// Parse an OCI `User` string in numeric `uid` or `uid:gid` form. When no gid
/// is given it defaults to the uid, matching common container behavior for
/// numeric users. Name resolution against the rootfs `/etc/passwd` is a
/// documented v1 non-goal.
fn parse_user(spec: &str) -> Result<(u32, u32), ConfigError> {
    let mut parts = spec.splitn(2, ':');
    let uid_str = parts.next().unwrap_or("");
    let uid: u32 = uid_str
        .parse()
        .map_err(|_| ConfigError::InvalidUser(spec.to_string()))?;
    let gid = match parts.next() {
        Some(gid_str) if !gid_str.is_empty() => gid_str
            .parse()
            .map_err(|_| ConfigError::InvalidUser(spec.to_string()))?,
        _ => uid,
    };
    Ok((uid, gid))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn base_config() -> GuestConfig {
        GuestConfig {
            schema_version: SCHEMA_VERSION,
            sandbox_id: "sb-1".into(),
            identity_nonce: "n-1".into(),
            rootfs: RootfsSpec {
                device: "/dev/vda".into(),
                fstype: "ext4".into(),
                readonly: false,
            },
            vsock_port: crate::protocol::DEFAULT_VSOCK_PORT,
            image_config: ImageConfig {
                env: vec!["PATH=/usr/bin".into(), "FOO=bar".into()],
                entrypoint: vec!["/bin/app".into()],
                cmd: vec!["--serve".into()],
                working_dir: "/app".into(),
                user: "1000:2000".into(),
            },
            overrides: ProcessOverrides::default(),
        }
    }

    #[test]
    fn parses_a_realistic_document() {
        let json = br#"{
            "schema_version": 1,
            "sandbox_id": "sb-abc",
            "identity_nonce": "nonce-xyz",
            "rootfs": {"device": "/dev/vda"},
            "image_config": {"Env": ["PATH=/bin"], "Cmd": ["/bin/sh"]},
            "overrides": {"env": {"DEBUG": "1"}}
        }"#;
        let cfg = GuestConfig::from_slice(json).expect("parse");
        assert_eq!(cfg.sandbox_id, "sb-abc");
        assert_eq!(cfg.rootfs.fstype, "ext4"); // defaulted
        assert_eq!(cfg.vsock_port, crate::protocol::DEFAULT_VSOCK_PORT); // defaulted
    }

    #[test]
    fn uses_image_config_when_no_overrides() {
        let p = base_config().resolve_process().expect("resolve");
        assert_eq!(p.argv, vec!["/bin/app", "--serve"]);
        assert_eq!(p.cwd, "/app");
        assert_eq!((p.uid, p.gid), (1000, 2000));
        assert_eq!(p.env, vec!["PATH=/usr/bin", "FOO=bar"]);
    }

    #[test]
    fn override_entrypoint_clears_image_cmd() {
        let mut c = base_config();
        c.overrides.entrypoint = Some(vec!["/bin/other".into()]);
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.argv, vec!["/bin/other"], "new entrypoint drops image cmd");
    }

    #[test]
    fn override_cmd_only_keeps_image_entrypoint() {
        let mut c = base_config();
        c.overrides.cmd = Some(vec!["--other".into()]);
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.argv, vec!["/bin/app", "--other"]);
    }

    #[test]
    fn override_both_entrypoint_and_cmd() {
        let mut c = base_config();
        c.overrides.entrypoint = Some(vec!["/bin/x".into()]);
        c.overrides.cmd = Some(vec!["a".into(), "b".into()]);
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.argv, vec!["/bin/x", "a", "b"]);
    }

    #[test]
    fn env_override_replaces_and_appends() {
        let mut c = base_config();
        let mut env = BTreeMap::new();
        env.insert("FOO".to_string(), "baz".to_string()); // replace
        env.insert("NEW".to_string(), "1".to_string()); // append
        c.overrides.env = env;
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.env, vec!["PATH=/usr/bin", "FOO=baz", "NEW=1"]);
    }

    #[test]
    fn workdir_and_user_overrides_win() {
        let mut c = base_config();
        c.overrides.workdir = Some("/data".into());
        c.overrides.user = Some("7".into());
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.cwd, "/data");
        assert_eq!((p.uid, p.gid), (7, 7), "bare uid defaults gid to uid");
    }

    #[test]
    fn empty_command_is_rejected() {
        let mut c = base_config();
        c.image_config.entrypoint.clear();
        c.image_config.cmd.clear();
        assert_eq!(c.resolve_process(), Err(ConfigError::EmptyCommand));
    }

    #[test]
    fn defaults_apply_when_image_and_overrides_silent() {
        let mut c = base_config();
        c.image_config.working_dir.clear();
        c.image_config.user.clear();
        let p = c.resolve_process().expect("resolve");
        assert_eq!(p.cwd, "/");
        assert_eq!((p.uid, p.gid), (0, 0));
    }

    #[test]
    fn unsupported_schema_is_rejected() {
        let mut c = base_config();
        c.schema_version = 99;
        assert_eq!(c.resolve_process(), Err(ConfigError::UnsupportedSchema(99)));
    }

    #[test]
    fn from_config_drive_trims_nul_padding() {
        let mut bytes = br#"{"schema_version":1,"sandbox_id":"s","identity_nonce":"n","rootfs":{"device":"/dev/vda"},"image_config":{"Cmd":["/bin/true"]}}"#.to_vec();
        bytes.extend(std::iter::repeat(0u8).take(512)); // simulate a padded block device
        let cfg = GuestConfig::from_config_drive(&bytes).expect("parse padded drive");
        assert_eq!(cfg.sandbox_id, "s");
    }

    #[test]
    fn invalid_user_is_rejected() {
        let mut c = base_config();
        c.overrides.user = Some("alice".into());
        assert_eq!(
            c.resolve_process(),
            Err(ConfigError::InvalidUser("alice".into()))
        );
    }
}
