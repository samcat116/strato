//! vsock control protocol between the host (sandbox runtime, issue #421) and
//! the guest agent.
//!
//! The wire format is **newline-delimited JSON**: each request is one JSON
//! object terminated by `\n`, and each response is one JSON object terminated
//! by `\n`. The guest listens on a well-known vsock port
//! ([`DEFAULT_VSOCK_PORT`], overridable via the config drive) and the host
//! connects to it.
//!
//! **v1 surface is deliberately tiny** (issue #419): a health `Ping` and a
//! `GetStatus` that returns the workload's lifecycle state and — once it has
//! ended — its exit code. Interactive exec / stdio streaming is phase 2
//! (issue #423) and intentionally absent here.
//!
//! Every response echoes the sandbox identity (`sandbox_id` + `nonce`). This
//! is what lets a host re-identify a guest after a phase-4 snapshot/resume
//! (issue #426): the listener is re-established on resume and the host
//! confirms it is talking to the sandbox it expects, not a stale generation.

use serde::{Deserialize, Serialize};

/// Well-known guest vsock port the agent listens on when the config drive does
/// not override it. Ports below 1024 are conventionally reserved; 1024 is the
/// first freely usable port and keeps us clear of them.
pub const DEFAULT_VSOCK_PORT: u32 = 1024;

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
}

/// A control response sent guest → host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    /// Reply to [`Request::Ping`].
    Pong { sandbox_id: String, nonce: String },
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
    /// The request could not be decoded or is not part of the v1 surface.
    Error { message: String },
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(decode_request("{\"type\":\"exec\"}").is_err());
    }

    #[test]
    fn pong_encodes_identity() {
        let resp = Response::Pong {
            sandbox_id: "sb-1".into(),
            nonce: "n-1".into(),
        };
        let line = encode_line(&resp);
        assert!(line.ends_with('\n'));
        assert_eq!(
            line.trim(),
            "{\"type\":\"pong\",\"sandbox_id\":\"sb-1\",\"nonce\":\"n-1\"}"
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
}
