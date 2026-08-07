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
//!   * the sandbox's identity and vsock port,
//!   * the OCI image config **plus** the sandbox's overrides — the guest does
//!     the merge, so OCI runtime semantics live in exactly one place, and
//!   * the NIC's L3 configuration, when the sandbox is networked (STR-101).
//!
//! The host side (issue #421) produces this document; the schema is versioned
//! so the two can evolve in lockstep.

use serde::{Deserialize, Serialize};

/// The newest config-drive schema version this init understands.
///
/// * v1 — the original document (identity, rootfs, vsock, process config).
/// * v2 — adds the optional [`NetworkConfig`] block (STR-101).
pub const SCHEMA_VERSION: u32 = 2;

/// The oldest schema version this init still understands. Every version in
/// `MINIMUM_SCHEMA_VERSION..=SCHEMA_VERSION` is accepted.
pub const MINIMUM_SCHEMA_VERSION: u32 = 1;

/// Top-level config-drive document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GuestConfig {
    /// The **minimum** schema version needed to act on this document, which the
    /// host stamps from what the document actually carries — not simply the
    /// newest version the host knows.
    ///
    /// So a network-free document is stamped v1 even by a host that can write
    /// v2, and keeps booting on an older guest image; a document carrying a
    /// [`NetworkConfig`] is stamped v2, and a guest that predates the block
    /// refuses it rather than booting a sandbox whose NIC it would silently
    /// ignore. A version this init understands but did not write is fine; one
    /// newer than [`SCHEMA_VERSION`] is not.
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
    /// Warm-start template mode (issue #426): boot fully — mount the rootfs,
    /// switch onto it, start the vsock agent — but park in the `held` state
    /// instead of launching a workload. The host snapshots the microVM at
    /// this point and later restores it for a *different* sandbox, delivering
    /// that sandbox's identity and process via a `launch` control request.
    #[serde(default)]
    pub warm_hold: bool,
    /// Hostname the guest boots under (STR-101).
    ///
    /// Deliberately *not* inside [`NetworkConfig`]: a hostname is a property of
    /// the sandbox, not of its NIC, and the fork path's `reidentify` already
    /// renames every restored guest regardless of whether it has one. Keeping
    /// it here is what stops two sandboxes of the same image from differing in
    /// hostname purely by NIC presence.
    #[serde(default)]
    pub hostname: Option<String>,
    /// The sandbox's single NIC, when it has one (STR-101). Absent for a
    /// network-free sandbox and for warm-start templates, which carry no
    /// network device at all.
    ///
    /// Statically configured rather than learned over DHCP: the control plane
    /// does IPAM and knows the address before the microVM boots, so a DHCP
    /// round trip on the cold-start path (and a client binary in a
    /// size-optimized initramfs) would only rediscover what is already here.
    /// OVN's DHCP responder stays programmed for the port, so an image that
    /// runs its own client keeps working — the guest just must not depend on
    /// it.
    #[serde(default)]
    pub network: Option<NetworkConfig>,
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

/// Static L3 configuration for the sandbox's single NIC (STR-101).
///
/// Everything here is known host-side before boot: the MAC the host programmed
/// on the virtio device, the addresses the control plane's IPAM allocated, and
/// the network's MTU/resolvers. The guest matches the interface by MAC (the
/// only stable handle — kernel interface names are enumeration order) and
/// applies the rest.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkConfig {
    /// MAC address of the NIC to configure, `aa:bb:cc:dd:ee:ff`. When absent
    /// the guest falls back to the sole non-loopback interface — a sandbox has
    /// at most one NIC, so that is unambiguous whenever it applies.
    #[serde(default)]
    pub mac_address: Option<String>,
    /// IPv4 address, prefix, and gateway. Absent on a v6-only network.
    #[serde(default)]
    pub ipv4: Option<AddressConfig>,
    /// IPv6 address, prefix, and gateway. Absent unless the network is
    /// dual-stack.
    #[serde(default)]
    pub ipv6: Option<AddressConfig>,
    /// Link MTU. Absent leaves the device's default (1500), which is wrong on
    /// any network whose uplink is encapsulated — so the host sends it
    /// whenever the logical network declares one.
    #[serde(default)]
    pub mtu: Option<u32>,
    /// Resolvers for `/etc/resolv.conf`.
    #[serde(default)]
    pub nameservers: Vec<String>,
    /// Search domains for `/etc/resolv.conf`, so unqualified lookups behave
    /// the same as they would for a DHCP guest given `domain_name`.
    #[serde(default)]
    pub search_domains: Vec<String>,
}

/// One address family's assignment: the address itself, its on-link prefix,
/// and the default gateway to route through.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddressConfig {
    /// The address in its family's textual form (dotted-quad or RFC 5952).
    pub address: String,
    /// On-link prefix length (0...32 for IPv4, 0...128 for IPv6). Carried as a
    /// number for both families — IPv6 has no dotted-netmask form.
    pub prefix_length: u8,
    /// Default gateway for this family. Absent leaves the guest with an
    /// on-link-only route, which is what an isolated network wants.
    #[serde(default)]
    pub gateway: Option<String>,
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
                    "unsupported config-drive schema version {v} \
                     (this init understands {MINIMUM_SCHEMA_VERSION}...{SCHEMA_VERSION}); \
                     the guest image is older than the agent that wrote this drive"
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
        // A version *older* than this build's is fully understood — the schema
        // is additive, and the host stamps the minimum a document needs — so
        // only a newer one is a refusal. That is what lets an agent that can
        // write v2 keep booting network-free sandboxes on a guest image that
        // predates the network block, while still refusing a document whose
        // NIC this init would silently ignore.
        if !(MINIMUM_SCHEMA_VERSION..=SCHEMA_VERSION).contains(&self.schema_version) {
            return Err(ConfigError::UnsupportedSchema(self.schema_version));
        }
        resolve_process(&self.image_config, &self.overrides)
    }
}

/// The image-config/overrides merge behind [`GuestConfig::resolve_process`],
/// callable without a full config document — the warm-start `launch` request
/// (issue #426) delivers exactly these two pieces over vsock and resolves
/// them with the same rules as a cold boot.
pub fn resolve_process(
    image_config: &ImageConfig,
    overrides: &ProcessOverrides,
) -> Result<ResolvedProcess, ConfigError> {
    let entrypoint = overrides
        .entrypoint
        .clone()
        .unwrap_or_else(|| image_config.entrypoint.clone());

    let cmd = match &overrides.cmd {
        Some(cmd) => cmd.clone(),
        None => {
            // A new entrypoint with no explicit cmd clears the image cmd.
            if overrides.entrypoint.is_some() {
                Vec::new()
            } else {
                image_config.cmd.clone()
            }
        }
    };

    let mut argv = entrypoint;
    argv.extend(cmd);
    if argv.is_empty() {
        return Err(ConfigError::EmptyCommand);
    }

    let env = merge_env(&image_config.env, &overrides.env);

    let cwd = overrides
        .workdir
        .clone()
        .filter(|w| !w.is_empty())
        .or_else(|| {
            if image_config.working_dir.is_empty() {
                None
            } else {
                Some(image_config.working_dir.clone())
            }
        })
        .unwrap_or_else(|| "/".to_string());

    let user_spec = overrides
        .user
        .clone()
        .filter(|u| !u.is_empty())
        .or_else(|| {
            if image_config.user.is_empty() {
                None
            } else {
                Some(image_config.user.clone())
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

/// Merge a base env (`KEY=VALUE` list) with an overrides map. Overrides
/// replace existing keys in place and are otherwise appended in sorted order,
/// so the result is deterministic. Used both for the image-config/sandbox
/// merge here and for exec sessions layering request env over the workload's
/// resolved env (issue #423).
pub fn merge_env(
    base_env: &[String],
    overrides: &std::collections::BTreeMap<String, String>,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(base_env.len() + overrides.len());
    let mut seen: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();

    for entry in base_env {
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
            warm_hold: false,
            hostname: None,
            network: None,
        }
    }

    #[test]
    fn parses_a_realistic_document() {
        let json = br#"{
            "schema_version": 2,
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
        assert!(
            cfg.network.is_none(),
            "a network-free sandbox omits the block"
        );
    }

    #[test]
    fn parses_a_dual_stack_network_block() {
        let json = br#"{
            "schema_version": 2,
            "sandbox_id": "sb-abc",
            "identity_nonce": "nonce-xyz",
            "rootfs": {"device": "/dev/vda"},
            "image_config": {"Cmd": ["/bin/sh"]},
            "hostname": "strato-abc123",
            "network": {
                "mac_address": "06:00:AC:10:00:05",
                "ipv4": {"address": "172.16.0.5", "prefix_length": 24, "gateway": "172.16.0.1"},
                "ipv6": {"address": "fd12:3456:789a::5", "prefix_length": 64, "gateway": "fd12:3456:789a::1"},
                "mtu": 1442,
                "nameservers": ["172.16.0.2"],
                "search_domains": ["proj.strato.internal"]
            }
        }"#;
        let cfg = GuestConfig::from_slice(json).expect("parse");
        // The hostname is a property of the sandbox, not of its NIC, so it
        // lives beside the identity rather than inside the network block.
        assert_eq!(cfg.hostname.as_deref(), Some("strato-abc123"));
        let net = cfg.network.expect("network block");
        assert_eq!(net.mac_address.as_deref(), Some("06:00:AC:10:00:05"));
        assert_eq!(
            net.ipv4,
            Some(AddressConfig {
                address: "172.16.0.5".into(),
                prefix_length: 24,
                gateway: Some("172.16.0.1".into()),
            })
        );
        assert_eq!(net.ipv6.as_ref().map(|a| a.prefix_length), Some(64));
        assert_eq!(net.mtu, Some(1442));
        assert_eq!(net.nameservers, vec!["172.16.0.2".to_string()]);
        assert_eq!(net.search_domains, vec!["proj.strato.internal".to_string()]);
    }

    #[test]
    fn network_block_tolerates_a_minimal_form() {
        // Every field but the addresses is optional: an isolated v4-only
        // network with no resolvers and no gateway is a legitimate shape.
        let json = br#"{
            "schema_version": 2,
            "sandbox_id": "s", "identity_nonce": "n",
            "rootfs": {"device": "/dev/vda"},
            "network": {"ipv4": {"address": "10.0.0.4", "prefix_length": 16}}
        }"#;
        let net = GuestConfig::from_slice(json)
            .expect("parse")
            .network
            .expect("network block");
        assert!(net.mac_address.is_none());
        assert!(net.ipv6.is_none());
        assert!(net.mtu.is_none());
        assert!(net.nameservers.is_empty());
        assert!(net.search_domains.is_empty());
        assert_eq!(net.ipv4.expect("v4").gateway, None);
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

    /// The host stamps the *minimum* version a document needs, so a v1 stamp
    /// from a newer agent means "this drive carries nothing past v1" — fully
    /// understood, and refusing it would strand every network-free sandbox on
    /// a node whose guest image lags the agent.
    #[test]
    fn an_older_schema_is_understood_rather_than_refused() {
        let mut c = base_config();
        c.schema_version = MINIMUM_SCHEMA_VERSION;
        assert!(c.resolve_process().is_ok());
    }

    /// A version past this build's is the one that must fail: it can only mean
    /// the drive carries something this init would silently ignore.
    #[test]
    fn a_newer_schema_is_refused() {
        let mut c = base_config();
        c.schema_version = SCHEMA_VERSION + 1;
        assert_eq!(
            c.resolve_process(),
            Err(ConfigError::UnsupportedSchema(SCHEMA_VERSION + 1))
        );
    }

    #[test]
    fn from_config_drive_trims_nul_padding() {
        let mut bytes = br#"{"schema_version":2,"sandbox_id":"s","identity_nonce":"n","rootfs":{"device":"/dev/vda"},"image_config":{"Cmd":["/bin/true"]}}"#.to_vec();
        bytes.extend(std::iter::repeat(0u8).take(512)); // simulate a padded block device
        let cfg = GuestConfig::from_config_drive(&bytes).expect("parse padded drive");
        assert_eq!(cfg.sandbox_id, "s");
    }

    #[test]
    fn warm_hold_defaults_to_false_and_parses() {
        let json = br#"{"schema_version":2,"sandbox_id":"s","identity_nonce":"n","rootfs":{"device":"/dev/vda"}}"#;
        let cfg = GuestConfig::from_slice(json).expect("parse");
        assert!(!cfg.warm_hold, "absent warm_hold must default to false");

        let json = br#"{"schema_version":2,"sandbox_id":"s","identity_nonce":"n","rootfs":{"device":"/dev/vda"},"warm_hold":true}"#;
        let cfg = GuestConfig::from_slice(json).expect("parse");
        assert!(cfg.warm_hold);
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
