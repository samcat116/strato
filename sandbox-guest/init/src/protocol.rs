//! vsock control protocol between the host (sandbox runtime, issue #421) and
//! the guest agent.
//!
//! The wire format is **newline-delimited JSON**: each request is one JSON
//! object terminated by `\n`, and each response is one JSON object terminated
//! by `\n`. The guest listens on a well-known vsock port
//! ([`DEFAULT_VSOCK_PORT`], overridable via the config drive) and the host
//! connects to it.
//!
//! **v1 surface** (issue #419): a health `Ping` and a `GetStatus` that returns
//! the workload's lifecycle state and — once it has ended — its exit code.
//!
//! **v2 surface** (issue #423) adds interactive exec and workload stdio
//! streaming. The first request on a connection determines its role:
//!
//! * `ping` / `get_status` — a request/response **control** connection that
//!   may serve many requests, exactly as in v1.
//! * `exec` — the connection becomes a dedicated **exec session**: the guest
//!   answers `exec_started` (or `error`), streams `output` lines, accepts
//!   interleaved `stdin` / `stdin_eof` / `resize` requests, and terminates
//!   with a single `exec_exit` before closing.
//! * `stream_logs` — the connection becomes a dedicated **log follow
//!   stream**: the guest replays retained workload stdio records from
//!   `since_seq` and then follows new output forever as `log` lines.
//!
//! All stdio payloads (`data` fields) are standard base64 so arbitrary bytes
//! survive the JSON framing.
//!
//! Every response echoes the guest generation's `nonce`. `pong` and `status`
//! additionally carry the historical `sandbox_id` field (used as the VM's
//! machine id by `strato-guest-agent`). The nonce lets a host reject output
//! from a stale guest generation, including in the middle of an exec stream.
//! The sandbox init receives its nonce from the config drive; the VM agent uses
//! Linux's boot id so restarting only the service preserves the generation.

use std::collections::BTreeMap;
use std::io::{self, BufRead};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::config::{ImageConfig, NetworkConfig, ProcessOverrides};

/// Well-known guest vsock port the agent listens on when the config drive does
/// not override it. Ports below 1024 are conventionally reserved; 1024 is the
/// first freely usable port and keeps us clear of them.
pub const DEFAULT_VSOCK_PORT: u32 = 1024;

/// Maximum accepted host request line, including its framing newline.
///
/// This matches the host response framer's 1 MiB ceiling. Keeping the bound in
/// the shared module means neither root-running guest speaker can accidentally
/// restore unbounded `read_line` allocation.
pub const MAX_REQUEST_LINE_BYTES: usize = 1 << 20;

/// Maximum UTF-8 size of identity fields accepted by the host parser.
pub const MAX_IDENTITY_BYTES: usize = 256;

/// Version of the guest control surface. This is advertised in `pong` so an
/// upgraded host can distinguish a new guest from an older init frozen inside
/// a checkpoint.
///
/// v4 (STR-104) adds the `network` block on [`Request::Launch`] and
/// [`Request::Reidentify`]: a guest restored from someone else's checkpoint
/// carries that sandbox's address in kernel memory, and re-addressing it in
/// place is what makes warm start and fork work for networked sandboxes.
pub const CONTROL_PROTOCOL_VERSION: u32 = 4;

/// Default for [`Request::Exec`]'s `tty` when the host omits it.
pub const DEFAULT_EXEC_TTY: bool = false;
/// Default PTY rows for [`Request::Exec`] when the host omits `rows`.
pub const DEFAULT_EXEC_ROWS: u16 = 24;
/// Default PTY columns for [`Request::Exec`] when the host omits `cols`.
pub const DEFAULT_EXEC_COLS: u16 = 80;

/// A control request sent host → guest. `type`-tagged for forward-compatible
/// decoding: an older guest rejects an unknown request rather than
/// misinterpreting it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    /// Liveness probe. Answered with [`Response::Pong`].
    Ping,
    /// Ask for the workload's current lifecycle state and exit code.
    GetStatus,
    /// Start an exec session on this connection (v2). Must be the first
    /// request on the connection.
    Exec {
        /// The command to run; must be non-empty.
        argv: Vec<String>,
        /// Extra environment merged **over** the workload's resolved env
        /// (replace on same key). `BTreeMap` for deterministic ordering.
        #[serde(default)]
        env: Option<BTreeMap<String, String>>,
        /// Working directory; defaults to the workload's resolved cwd.
        #[serde(default)]
        cwd: Option<String>,
        /// Allocate a PTY. Defaults to [`DEFAULT_EXEC_TTY`].
        #[serde(default)]
        tty: Option<bool>,
        /// Initial PTY rows (tty only). Defaults to [`DEFAULT_EXEC_ROWS`].
        #[serde(default)]
        rows: Option<u16>,
        /// Initial PTY columns (tty only). Defaults to [`DEFAULT_EXEC_COLS`].
        #[serde(default)]
        cols: Option<u16>,
    },
    /// Write bytes (base64) to the exec child's stdin. Exec sessions only.
    Stdin {
        /// base64-encoded bytes for the child's stdin.
        data: String,
    },
    /// Close the exec child's stdin (no more `stdin` will follow). For tty
    /// sessions this only stops writes. Exec sessions only.
    StdinEof,
    /// Resize the exec session's PTY. Ignored for non-tty sessions.
    Resize { rows: u16, cols: u16 },
    /// Start a log follow stream on this connection (v2). Must be the first
    /// request on the connection; the host sends nothing afterwards.
    StreamLogs {
        /// First workload-log sequence number the host wants. Records already
        /// evicted from the ring buffer are silently skipped (delivery starts
        /// at the oldest retained).
        since_seq: u64,
    },
    /// Set the guest's realtime clock (v3, issue #426). Sent by the host
    /// right after restoring the guest from a snapshot, whose wall clock
    /// resumed frozen at checkpoint time. Answered with
    /// [`Response::ClockSynced`].
    SyncClock {
        /// Current host wall-clock time as nanoseconds since the Unix epoch.
        unix_nanos: i64,
    },
    /// Launch the workload in a guest booted with `warm_hold` (v4, issue
    /// #426 warm start). Sent by the host after restoring a warm-template
    /// snapshot for a new sandbox: the guest mixes the host-supplied
    /// entropy into the kernel RNG (the snapshot froze the entropy pool),
    /// resolves the process exactly as a cold boot would, execs it, and —
    /// only on success — adopts the delivered identity. Answered with
    /// [`Response::Launched`] (or [`Response::Error`] if the guest is not
    /// `held` or the spawn fails, in which case it stays `held` under the
    /// template identity, recoverable by a retry or demotion).
    Launch {
        /// The restored-into sandbox's control-plane id.
        sandbox_id: String,
        /// The restored-into sandbox's boot nonce; echoed in every control
        /// response from here on, replacing the template's.
        identity_nonce: String,
        /// The OCI image `config` subset, as on the config drive. Boxed to
        /// keep the request enum small (serde is transparent to the Box).
        #[serde(default)]
        image_config: Box<ImageConfig>,
        /// The sandbox spec's process overrides, as on the config drive.
        #[serde(default)]
        overrides: Box<ProcessOverrides>,
        /// base64 random bytes to mix into `/dev/urandom`. Warm launch keeps
        /// this best-effort; user-checkpoint fork re-identification requires
        /// the same reseed operation to succeed.
        #[serde(default)]
        entropy: Option<String>,
        /// Hostname the restored-into sandbox boots under (STR-101).
        ///
        /// A template guest set the *template's* hostname (or none) at its own
        /// boot, so without this a warm-launched sandbox would keep it while a
        /// cold-booted one got its own — the same "differ by provisioning
        /// path" asymmetry that keeps the hostname out of the config drive's
        /// network block. Optional and best-effort: absent from older hosts,
        /// and a rename failing must not fail the launch.
        #[serde(default)]
        hostname: Option<String>,
        /// The launched-into sandbox's NIC configuration (v4, STR-104).
        ///
        /// A warm template carries a network *device* but no addressing — it
        /// is shared across sandboxes, so it holds nothing sandbox-specific —
        /// and the host repoints that device at the sandbox's own TAP as it
        /// loads the snapshot. This is the other half: the MAC, addresses,
        /// routes, MTU and resolvers the guest applies to it, exactly what a
        /// cold boot would have read off the config drive.
        ///
        /// Absent for a network-free sandbox. Unlike the hostname this is
        /// **not** best effort: a sandbox that reports running must be on the
        /// network its desired state says it is, so a failure leaves the guest
        /// `held` for the host to retry or demote.
        #[serde(default)]
        network: Option<Box<NetworkConfig>>,
    },
    /// Rotate all guest identity material after restoring a user checkpoint as
    /// a new sandbox (v5, issue #427). The source fields prevent a host from
    /// mutating a guest whose checkpoint identity did not match its metadata.
    Reidentify {
        expected_sandbox_id: String,
        expected_nonce: String,
        sandbox_id: String,
        identity_nonce: String,
        hostname: String,
        /// Fresh host randomness, base64 encoded; at least 32 bytes required.
        entropy: String,
        /// Current wall clock as nanoseconds since the Unix epoch.
        unix_nanos: i64,
        /// The fork target's NIC configuration (v4, STR-104).
        ///
        /// The checkpointed guest holds the *source* sandbox's MAC and address
        /// in kernel memory, and the target has its own IPAM allocation, so a
        /// fork that skipped this would boot onto the network claiming an
        /// address that belongs to something else. Absent when the fork has no
        /// NIC; strict, like every other step of re-identification.
        #[serde(default)]
        network: Option<Box<NetworkConfig>>,
    },
}

/// The workload's lifecycle state as observed by the guest agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkloadState {
    /// The init is still bringing the workload up (mounting, pivoting).
    Starting,
    /// The workload process is running.
    Running,
    /// The workload process has ended; see `exit_code`.
    Exited,
    /// Warm-start template hold (issue #426): the guest is fully booted but
    /// deliberately has no workload; it is waiting to be snapshotted, or —
    /// after a restore — for a `launch` request.
    Held,
}

/// A control response sent guest → host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    /// Reply to [`Request::Ping`].
    Pong {
        sandbox_id: String,
        nonce: String,
        control_protocol_version: u32,
    },
    /// Reply to [`Request::GetStatus`].
    Status {
        sandbox_id: String,
        nonce: String,
        state: WorkloadState,
        /// The workload's exit code, present only once `state == Exited`.
        /// A process killed by signal N is reported as `128 + N`, matching
        /// shell conventions, so the host always sees a single integer.
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
    },
    /// Sent once on an exec session after the child spawned successfully.
    ExecStarted { nonce: String },
    /// A chunk of exec child output. For tty sessions everything is reported
    /// as stream `"stdout"`; non-tty sessions report `"stdout"` and
    /// `"stderr"` separately.
    Output {
        nonce: String,
        stream: String,
        /// base64-encoded output bytes.
        data: String,
    },
    /// Terminal exec-session message: the child was reaped (signal N reported
    /// as `128 + N`) and all buffered output has been flushed. The guest
    /// closes the connection after sending it.
    ExecExit { nonce: String, exit_code: i32 },
    /// One retained/live workload stdio record on a log follow stream.
    Log {
        nonce: String,
        /// Monotonic sequence number, starting at 1, shared across streams.
        seq: u64,
        /// `"stdout"` or `"stderr"`.
        stream: String,
        /// base64-encoded chunk bytes.
        data: String,
    },
    /// Terminal log-follow message: the workload's stdio pipes have all hit
    /// EOF and every retained record was delivered — no log record will ever
    /// follow. Lets the host flush a partial final line (output that ended
    /// without a trailing newline) instead of holding it until teardown. The
    /// guest closes the connection after sending it.
    LogEof { nonce: String },
    /// Reply to [`Request::SyncClock`]: the realtime clock was set.
    ClockSynced { nonce: String },
    /// Reply to [`Request::Launch`]: the workload spawned under the new
    /// identity. Subsequent `pong`/`status` responses echo the launched
    /// sandbox's identity.
    Launched { nonce: String },
    /// Reply to [`Request::Reidentify`]. All later identity-bearing responses
    /// echo the target sandbox id and nonce.
    Reidentified { nonce: String },
    /// The request could not be decoded, is not valid for the connection's
    /// role, or the exec spawn failed.
    Error { nonce: String, message: String },
}

impl Response {
    /// The guest-generation nonce carried by every response variant.
    ///
    /// Keeping this match exhaustive makes adding an identity-less response a
    /// compile error in both guest binaries.
    pub fn nonce(&self) -> &str {
        match self {
            Response::Pong { nonce, .. }
            | Response::Status { nonce, .. }
            | Response::ExecStarted { nonce }
            | Response::Output { nonce, .. }
            | Response::ExecExit { nonce, .. }
            | Response::Log { nonce, .. }
            | Response::LogEof { nonce }
            | Response::ClockSynced { nonce }
            | Response::Launched { nonce }
            | Response::Reidentified { nonce }
            | Response::Error { nonce, .. } => nonce,
        }
    }
}

/// Encode bytes as standard base64 for a protocol `data` field.
pub fn encode_base64(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}

/// Decode a protocol `data` field (standard base64) back into bytes.
pub fn decode_base64(data: &str) -> Result<Vec<u8>, base64::DecodeError> {
    BASE64.decode(data)
}

/// Encode a response as a single newline-terminated JSON line.
pub fn encode_line<T: Serialize>(value: &T) -> String {
    let mut line = serde_json::to_string(value).unwrap_or_else(|e| {
        // Serialization of these small owned types cannot realistically fail;
        // fall back to a valid error line rather than panicking in PID 1.
        format!("{{\"type\":\"error\",\"message\":\"encode failed: {e}\"}}")
    });
    line.push('\n');
    line
}

/// Decode one request line (without the trailing newline).
pub fn decode_request(line: &str) -> Result<Request, serde_json::Error> {
    serde_json::from_str(line.trim())
}

/// Read one request line without allocating beyond the protocol ceiling.
///
/// `Ok(0)` is EOF. A line longer than [`MAX_REQUEST_LINE_BYTES`] is consumed
/// only through the first byte past the limit and rejected; connection handlers
/// close that connection rather than attempting to resynchronize it.
pub fn read_request_line(reader: &mut impl BufRead, line: &mut String) -> io::Result<usize> {
    line.clear();
    let mut limited = std::io::Read::take(reader, (MAX_REQUEST_LINE_BYTES + 1) as u64);
    let bytes = limited.read_line(line)?;
    if bytes > MAX_REQUEST_LINE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("request line exceeds {MAX_REQUEST_LINE_BYTES} bytes"),
        ));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn ping_round_trips() {
        let req = decode_request("{\"type\":\"ping\"}").expect("decode");
        assert_eq!(req, Request::Ping);
    }

    #[test]
    fn get_status_round_trips() {
        let req = decode_request("  {\"type\":\"get_status\"}\n").expect("decode with whitespace");
        assert_eq!(req, Request::GetStatus);
    }

    #[test]
    fn unknown_request_is_rejected() {
        assert!(decode_request("{\"type\":\"reboot\"}").is_err());
    }

    #[test]
    fn request_line_reader_enforces_shared_ceiling() {
        let at_limit = vec![b' '; MAX_REQUEST_LINE_BYTES];
        let mut reader = Cursor::new(at_limit);
        let mut line = String::new();
        assert_eq!(
            read_request_line(&mut reader, &mut line).expect("line at limit"),
            MAX_REQUEST_LINE_BYTES
        );

        let over_limit = vec![b' '; MAX_REQUEST_LINE_BYTES + 1];
        let mut reader = Cursor::new(over_limit);
        let err = read_request_line(&mut reader, &mut line).expect_err("oversized line");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn sync_clock_round_trips() {
        let req = decode_request(r#"{"type":"sync_clock","unix_nanos":1752700000000000000}"#)
            .expect("decode");
        assert_eq!(
            req,
            Request::SyncClock {
                unix_nanos: 1_752_700_000_000_000_000
            }
        );
        let decoded: Request = serde_json::from_str(encode_line(&req).trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn launch_round_trips() {
        let line = r#"{"type":"launch","sandbox_id":"sb-2","identity_nonce":"n-2","image_config":{"Env":["PATH=/bin"],"Cmd":["/bin/sh"]},"overrides":{"env":{"DEBUG":"1"}},"entropy":"c2VlZA==","hostname":"strato-sb2","network":{"mac_address":"06:00:ac:10:00:07","ipv4":{"address":"172.16.0.7","prefix_length":24,"gateway":"172.16.0.1"}}}"#;
        let req = decode_request(line).expect("decode");
        match &req {
            Request::Launch {
                sandbox_id,
                identity_nonce,
                image_config,
                overrides,
                entropy,
                hostname,
                network,
            } => {
                assert_eq!(sandbox_id, "sb-2");
                assert_eq!(identity_nonce, "n-2");
                assert_eq!(image_config.cmd, vec!["/bin/sh"]);
                assert_eq!(overrides.env.get("DEBUG").map(String::as_str), Some("1"));
                assert_eq!(entropy.as_deref(), Some("c2VlZA=="));
                assert_eq!(hostname.as_deref(), Some("strato-sb2"));
                assert_eq!(
                    network.as_ref().and_then(|n| n.mac_address.as_deref()),
                    Some("06:00:ac:10:00:07")
                );
            }
            other => panic!("decoded wrong variant: {other:?}"),
        }
        let decoded: Request = serde_json::from_str(encode_line(&req).trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    /// A host that predates the hostname field (or has no name to give) sends
    /// no key, and the guest keeps whatever it booted with. Likewise `network`:
    /// its absence is a network-free sandbox, not a NIC to leave misconfigured.
    #[test]
    fn launch_minimal_defaults_config_entropy_and_hostname() {
        let req = decode_request(r#"{"type":"launch","sandbox_id":"sb-3","identity_nonce":"n-3"}"#)
            .expect("decode minimal");
        assert_eq!(
            req,
            Request::Launch {
                sandbox_id: "sb-3".into(),
                identity_nonce: "n-3".into(),
                image_config: Box::default(),
                overrides: Box::default(),
                entropy: None,
                hostname: None,
                network: None,
            }
        );
    }

    #[test]
    fn launched_encodes_identity_nonce() {
        let response = Response::Launched {
            nonce: "n-2".into(),
        };
        let line = encode_line(&response);
        assert_eq!(line.trim(), r#"{"type":"launched","nonce":"n-2"}"#);
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, response);
    }

    #[test]
    fn reidentify_round_trips() {
        let line = r#"{"type":"reidentify","expected_sandbox_id":"source","expected_nonce":"old","sandbox_id":"fork","identity_nonce":"new","hostname":"strato-fork","entropy":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=","unix_nanos":1752700000000000000}"#;
        let req = decode_request(line).expect("decode");
        assert!(
            matches!(&req, Request::Reidentify { network, .. } if network.is_none()),
            "a network-free fork sends no network block"
        );
        let decoded: Request = serde_json::from_str(encode_line(&req).trim()).expect("re-decode");
        assert_eq!(decoded, req);
        assert_eq!(
            encode_line(&Response::Reidentified {
                nonce: "new".into()
            })
            .trim(),
            r#"{"type":"reidentified","nonce":"new"}"#
        );
    }

    /// The fork target's own addressing rides the same request that rotates
    /// its identity, so the guest never runs a moment with the source's
    /// address under the target's name (STR-104).
    #[test]
    fn reidentify_carries_the_targets_network() {
        let line = r#"{"type":"reidentify","expected_sandbox_id":"source","expected_nonce":"old","sandbox_id":"fork","identity_nonce":"new","hostname":"strato-fork","entropy":"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=","unix_nanos":1752700000000000000,"network":{"mac_address":"06:00:ac:10:00:09","ipv4":{"address":"172.16.0.9","prefix_length":24,"gateway":"172.16.0.1"},"mtu":1442,"nameservers":["172.16.0.2"],"search_domains":["proj.strato.internal"]}}"#;
        let req = decode_request(line).expect("decode");
        match &req {
            Request::Reidentify { network, .. } => {
                let network = network.as_ref().expect("network block");
                assert_eq!(network.mac_address.as_deref(), Some("06:00:ac:10:00:09"));
                assert_eq!(
                    network.ipv4.as_ref().map(|a| a.address.as_str()),
                    Some("172.16.0.9")
                );
                assert_eq!(network.mtu, Some(1442));
            }
            other => panic!("decoded wrong variant: {other:?}"),
        }
        let decoded: Request = serde_json::from_str(encode_line(&req).trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn held_state_serializes_snake_case() {
        let resp = Response::Status {
            sandbox_id: "sb-1".into(),
            nonce: "n-1".into(),
            state: WorkloadState::Held,
            exit_code: None,
        };
        let line = encode_line(&resp);
        assert!(
            line.contains(r#""state":"held""#),
            "held must serialize snake_case: {line}"
        );
    }

    #[test]
    fn clock_synced_encodes() {
        assert_eq!(
            encode_line(&Response::ClockSynced {
                nonce: "n-1".into()
            })
            .trim(),
            r#"{"type":"clock_synced","nonce":"n-1"}"#
        );
    }

    #[test]
    fn exec_decodes_full_form() {
        let req = decode_request(
            r#"{"type":"exec","argv":["/bin/sh"],"env":{"FOO":"bar"},"cwd":"/app","tty":true,"rows":24,"cols":80}"#,
        )
        .expect("decode");
        let mut env = BTreeMap::new();
        env.insert("FOO".to_string(), "bar".to_string());
        assert_eq!(
            req,
            Request::Exec {
                argv: vec!["/bin/sh".into()],
                env: Some(env),
                cwd: Some("/app".into()),
                tty: Some(true),
                rows: Some(24),
                cols: Some(80),
            }
        );
    }

    #[test]
    fn exec_optional_fields_default_to_none() {
        let req =
            decode_request(r#"{"type":"exec","argv":["/bin/true"]}"#).expect("decode minimal");
        assert_eq!(
            req,
            Request::Exec {
                argv: vec!["/bin/true".into()],
                env: None,
                cwd: None,
                tty: None,
                rows: None,
                cols: None,
            }
        );
    }

    #[test]
    fn exec_round_trips() {
        let req = Request::Exec {
            argv: vec!["/bin/sh".into(), "-c".into(), "id".into()],
            env: None,
            cwd: None,
            tty: Some(false),
            rows: None,
            cols: None,
        };
        let line = encode_line(&req);
        let decoded: Request = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn stdin_round_trips() {
        let req = decode_request(r#"{"type":"stdin","data":"aGVsbG8="}"#).expect("decode");
        assert_eq!(
            req,
            Request::Stdin {
                data: "aGVsbG8=".into()
            }
        );
        let line = encode_line(&req);
        let decoded: Request = serde_json::from_str(line.trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn stdin_eof_round_trips() {
        let req = decode_request(r#"{"type":"stdin_eof"}"#).expect("decode");
        assert_eq!(req, Request::StdinEof);
        assert_eq!(encode_line(&req).trim(), r#"{"type":"stdin_eof"}"#);
    }

    #[test]
    fn resize_round_trips() {
        let req = decode_request(r#"{"type":"resize","rows":30,"cols":100}"#).expect("decode");
        assert_eq!(
            req,
            Request::Resize {
                rows: 30,
                cols: 100
            }
        );
        let line = encode_line(&req);
        let decoded: Request = serde_json::from_str(line.trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn stream_logs_round_trips() {
        let req = decode_request(r#"{"type":"stream_logs","since_seq":17}"#).expect("decode");
        assert_eq!(req, Request::StreamLogs { since_seq: 17 });
        let line = encode_line(&req);
        let decoded: Request = serde_json::from_str(line.trim()).expect("re-decode");
        assert_eq!(decoded, req);
    }

    #[test]
    fn pong_encodes_identity() {
        let resp = Response::Pong {
            sandbox_id: "sb-1".into(),
            nonce: "n-1".into(),
            control_protocol_version: CONTROL_PROTOCOL_VERSION,
        };
        let line = encode_line(&resp);
        assert!(line.ends_with('\n'));
        assert_eq!(
            line.trim(),
            "{\"type\":\"pong\",\"sandbox_id\":\"sb-1\",\"nonce\":\"n-1\",\"control_protocol_version\":4}"
        );
    }

    #[test]
    fn status_omits_exit_code_while_running() {
        let resp = Response::Status {
            sandbox_id: "sb-1".into(),
            nonce: "n-1".into(),
            state: WorkloadState::Running,
            exit_code: None,
        };
        let line = encode_line(&resp);
        assert!(
            !line.contains("exit_code"),
            "running status must omit exit_code: {line}"
        );
    }

    #[test]
    fn status_includes_exit_code_when_exited() {
        let resp = Response::Status {
            sandbox_id: "sb-1".into(),
            nonce: "n-1".into(),
            state: WorkloadState::Exited,
            exit_code: Some(0),
        };
        let line = encode_line(&resp);
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, resp);
    }

    #[test]
    fn exec_started_encodes_as_spec() {
        let response = Response::ExecStarted {
            nonce: "n-1".into(),
        };
        let line = encode_line(&response);
        assert_eq!(line.trim(), r#"{"type":"exec_started","nonce":"n-1"}"#);
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, response);
    }

    #[test]
    fn output_round_trips() {
        let resp = Response::Output {
            nonce: "n-1".into(),
            stream: "stderr".into(),
            data: encode_base64(b"oops\n"),
        };
        let line = encode_line(&resp);
        assert_eq!(
            line.trim(),
            r#"{"type":"output","nonce":"n-1","stream":"stderr","data":"b29wcwo="}"#
        );
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, resp);
    }

    #[test]
    fn exec_exit_round_trips() {
        let resp = Response::ExecExit {
            nonce: "n-1".into(),
            exit_code: 137,
        };
        let line = encode_line(&resp);
        assert_eq!(
            line.trim(),
            r#"{"type":"exec_exit","nonce":"n-1","exit_code":137}"#
        );
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, resp);
    }

    #[test]
    fn log_round_trips() {
        let resp = Response::Log {
            nonce: "n-1".into(),
            seq: 18,
            stream: "stdout".into(),
            data: encode_base64(b"line\n"),
        };
        let line = encode_line(&resp);
        assert_eq!(
            line.trim(),
            r#"{"type":"log","nonce":"n-1","seq":18,"stream":"stdout","data":"bGluZQo="}"#
        );
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, resp);
    }

    #[test]
    fn log_eof_encodes_identity_nonce() {
        let response = Response::LogEof {
            nonce: "n-1".into(),
        };
        let line = encode_line(&response);
        assert_eq!(line.trim(), r#"{"type":"log_eof","nonce":"n-1"}"#);
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded, response);
    }

    #[test]
    fn error_round_trips_with_identity_nonce() {
        let response = Response::Error {
            nonce: "n-1".into(),
            message: "boom".into(),
        };
        let line = encode_line(&response);
        assert_eq!(
            line.trim(),
            r#"{"type":"error","nonce":"n-1","message":"boom"}"#
        );
        let decoded: Response = serde_json::from_str(line.trim()).expect("decode");
        assert_eq!(decoded.nonce(), "n-1");
        assert_eq!(decoded, response);
    }

    #[test]
    fn base64_round_trips_arbitrary_bytes() {
        let bytes: Vec<u8> = (0..=255).collect();
        let encoded = encode_base64(&bytes);
        assert_eq!(decode_base64(&encoded).expect("decode"), bytes);
    }

    #[test]
    fn base64_rejects_garbage() {
        assert!(decode_base64("not base64!!").is_err());
    }
}
