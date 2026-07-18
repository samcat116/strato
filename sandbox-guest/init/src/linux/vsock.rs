//! The vsock control agent (Linux only).
//!
//! Listens on `AF_VSOCK` for the host (issue #421) and serves the v2 control
//! surface (issue #423) with one thread per connection, so control polls keep
//! working while exec sessions and log streams are active. The connection's
//! **first decoded request determines its role**:
//!
//! * `ping` / `get_status` — a request/response control connection that may
//!   serve many requests, exactly as v1 did;
//! * `exec` — a dedicated exec session (see [`super::exec`]);
//! * `stream_logs` — a dedicated workload-log follow stream (see
//!   [`super::logs`]).
//!
//! Status is read from a shared [`SharedStatus`] the reaper updates, so a
//! `get_status` after the workload has ended returns its exit code. The
//! listener is intentionally simple and idempotent — it can be re-created
//! after a snapshot/resume (phase 4) and every control response carries the
//! sandbox identity + boot nonce so the host can confirm which generation it
//! reached.

use std::io::{BufRead, BufReader, Write};
use std::mem;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::io::AsRawFd;
use std::sync::{Arc, Mutex};

use strato_sandbox_init::config::ResolvedProcess;
use strato_sandbox_init::logbuf::LogBuffer;
use strato_sandbox_init::protocol::{
    decode_request, encode_line, Request, Response, WorkloadState,
};

use super::exec::{self, ExecRequest};
use super::logs;
use super::reaper::ChildRegistry;

/// Workload lifecycle state shared between the reaper (writer) and the vsock
/// agent (reader).
#[derive(Debug, Clone)]
pub struct Status {
    pub sandbox_id: String,
    pub nonce: String,
    pub state: WorkloadState,
    pub exit_code: Option<i32>,
}

pub type SharedStatus = Arc<Mutex<Status>>;

/// Everything a vsock connection may need, shared across connection threads.
pub struct GuestState {
    /// Live workload status, updated by the reaper.
    pub status: SharedStatus,
    /// The workload's resolved process — exec sessions inherit its env, cwd,
    /// and uid/gid as their defaults.
    pub process: ResolvedProcess,
    /// Ring buffer of captured workload stdout/stderr.
    pub logs: Arc<LogBuffer>,
    /// Exit-code routing between PID 1's reaper and exec sessions.
    pub children: Arc<ChildRegistry>,
}

/// Bind the guest vsock port and serve connections forever, one thread each.
/// Returns only on a fatal bind/listen error; per-connection errors are
/// logged and swallowed so a misbehaving client cannot take the agent down.
pub fn serve(port: u32, state: Arc<GuestState>) -> Result<(), String> {
    let listener = bind_listener(port)?;
    loop {
        // SAFETY: accept(2) returns a fresh, owned connected socket fd.
        let raw = unsafe {
            libc::accept(
                listener.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if raw < 0 {
            let err = std::io::Error::last_os_error();
            // EINTR/ECONNABORTED are transient; keep serving.
            eprintln!("[sandbox-init] vsock accept failed: {err}");
            continue;
        }
        let conn = unsafe { OwnedFd::from_raw_fd(raw) };
        let state = Arc::clone(&state);
        let spawned = std::thread::Builder::new()
            .name("vsock-conn".to_string())
            .spawn(move || {
                if let Err(e) = handle_connection(conn, &state) {
                    eprintln!("[sandbox-init] vsock connection error: {e}");
                }
            });
        if let Err(e) = spawned {
            // Drop the connection; the host will retry.
            eprintln!("[sandbox-init] vsock: spawn connection thread: {e}");
        }
    }
}

fn bind_listener(port: u32) -> Result<OwnedFd, String> {
    // SAFETY: standard socket(2)/bind(2)/listen(2) on AF_VSOCK.
    unsafe {
        let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err(format!(
                "socket(AF_VSOCK): {}",
                std::io::Error::last_os_error()
            ));
        }
        let owned = OwnedFd::from_raw_fd(fd);

        let mut addr: libc::sockaddr_vm = mem::zeroed();
        addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        addr.svm_cid = libc::VMADDR_CID_ANY;
        addr.svm_port = port;
        let rc = libc::bind(
            owned.as_raw_fd(),
            &addr as *const libc::sockaddr_vm as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        );
        if rc < 0 {
            return Err(format!(
                "bind(vsock:{port}): {}",
                std::io::Error::last_os_error()
            ));
        }
        if libc::listen(owned.as_raw_fd(), 8) < 0 {
            return Err(format!(
                "listen(vsock:{port}): {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(owned)
    }
}

/// Read the connection's first request and dispatch by role.
fn handle_connection(conn: OwnedFd, state: &GuestState) -> std::io::Result<()> {
    // One fd, read and write halves; clone for buffered reading.
    let write_fd = conn.try_clone()?;
    let mut writer = std::fs::File::from(write_fd);
    let mut reader = BufReader::new(std::fs::File::from(conn));

    let mut first = String::new();
    loop {
        first.clear();
        if reader.read_line(&mut first)? == 0 {
            return Ok(()); // closed without ever sending a request
        }
        if !first.trim().is_empty() {
            break;
        }
    }

    match decode_request(&first) {
        Ok(req @ (Request::Ping | Request::GetStatus | Request::SyncClock { .. })) => {
            serve_control(req, reader, writer, &state.status)
        }
        Ok(Request::Exec {
            argv,
            env,
            cwd,
            tty,
            rows,
            cols,
        }) => {
            exec::run_exec_session(
                reader,
                writer,
                ExecRequest {
                    argv,
                    env,
                    cwd,
                    tty,
                    rows,
                    cols,
                },
                state,
            );
            Ok(())
        }
        Ok(Request::StreamLogs { since_seq }) => {
            logs::run_follow_stream(reader, writer, since_seq, &state.logs);
            Ok(())
        }
        Ok(_) => {
            let resp = Response::Error {
                message: "stdin/stdin_eof/resize are only valid within an exec session".to_string(),
            };
            writer.write_all(encode_line(&resp).as_bytes())?;
            writer.flush()
        }
        Err(e) => {
            let resp = Response::Error {
                message: format!("undecodable request: {e}"),
            };
            writer.write_all(encode_line(&resp).as_bytes())?;
            writer.flush()
        }
    }
}

/// v1-style request/response loop for control connections.
fn serve_control(
    first: Request,
    reader: BufReader<std::fs::File>,
    mut writer: std::fs::File,
    status: &SharedStatus,
) -> std::io::Result<()> {
    let response = control_response(&first, status);
    writer.write_all(encode_line(&response).as_bytes())?;
    writer.flush()?;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match decode_request(&line) {
            Ok(req @ (Request::Ping | Request::GetStatus | Request::SyncClock { .. })) => {
                control_response(&req, status)
            }
            Ok(_) => Response::Error {
                message: "only ping/get_status/sync_clock are valid on a control connection"
                    .to_string(),
            },
            Err(e) => Response::Error {
                message: format!("undecodable request: {e}"),
            },
        };
        writer.write_all(encode_line(&response).as_bytes())?;
        writer.flush()?;
    }
    Ok(())
}

fn control_response(request: &Request, status: &SharedStatus) -> Response {
    // Clock sync is stateless — handle it before taking the status lock.
    if let Request::SyncClock { unix_nanos } = request {
        return match set_realtime_clock(*unix_nanos) {
            Ok(()) => Response::ClockSynced,
            Err(e) => Response::Error {
                message: format!("clock_settime failed: {e}"),
            },
        };
    }

    let s = status.lock().expect("status poisoned");
    match request {
        Request::GetStatus => Response::Status {
            sandbox_id: s.sandbox_id.clone(),
            nonce: s.nonce.clone(),
            state: s.state,
            exit_code: s.exit_code,
        },
        // serve_control is only ever called with the control subset; answer
        // Pong for anything that is not GetStatus rather than panicking.
        _ => Response::Pong {
            sandbox_id: s.sandbox_id.clone(),
            nonce: s.nonce.clone(),
        },
    }
}

/// Set CLOCK_REALTIME (issue #426): a guest restored from a snapshot resumes
/// with the wall clock it was checkpointed with, so the host pushes the
/// current time right after a restore. PID 1 has CAP_SYS_TIME, so this only
/// fails on a nonsensical timestamp.
fn set_realtime_clock(unix_nanos: i64) -> Result<(), String> {
    if unix_nanos < 0 {
        return Err("timestamp is before the Unix epoch".to_string());
    }
    let ts = libc::timespec {
        tv_sec: (unix_nanos / 1_000_000_000) as _,
        tv_nsec: (unix_nanos % 1_000_000_000) as _,
    };
    let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
    }
}
