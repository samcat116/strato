//! The vsock control agent (Linux only).
//!
//! Listens on `AF_VSOCK` for the host (issue #421) and answers the v1 control
//! surface: `Ping` and `GetStatus`. It reads the workload's live state from a
//! shared [`SharedStatus`] the reaper updates, so a `GetStatus` after the
//! workload has ended returns its exit code.
//!
//! The listener is intentionally simple and idempotent — it can be re-created
//! after a snapshot/resume (phase 4) and every response carries the sandbox
//! identity + boot nonce so the host can confirm which generation it reached.

use std::io::{BufRead, BufReader, Write};
use std::mem;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::io::AsRawFd;
use std::sync::{Arc, Mutex};

use strato_sandbox_init::protocol::{
    decode_request, encode_line, Request, Response, WorkloadState,
};

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

/// Bind the guest vsock port and serve control connections forever. Returns
/// only on a fatal bind/listen error; per-connection errors are logged and
/// swallowed so a misbehaving client cannot take the agent down.
pub fn serve(port: u32, status: SharedStatus) -> Result<(), String> {
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
        if let Err(e) = handle_connection(conn, &status) {
            eprintln!("[sandbox-init] vsock connection error: {e}");
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

fn handle_connection(conn: OwnedFd, status: &SharedStatus) -> std::io::Result<()> {
    // One fd, read and write halves; clone for buffered reading.
    let write_fd = conn.try_clone()?;
    let mut writer = std::fs::File::from(write_fd);
    let reader = BufReader::new(std::fs::File::from(conn));

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match decode_request(&line) {
            Ok(Request::Ping) => {
                let s = status.lock().expect("status poisoned");
                Response::Pong {
                    sandbox_id: s.sandbox_id.clone(),
                    nonce: s.nonce.clone(),
                }
            }
            Ok(Request::GetStatus) => {
                let s = status.lock().expect("status poisoned");
                Response::Status {
                    sandbox_id: s.sandbox_id.clone(),
                    nonce: s.nonce.clone(),
                    state: s.state,
                    exit_code: s.exit_code,
                }
            }
            Err(e) => Response::Error {
                message: format!("undecodable request: {e}"),
            },
        };
        writer.write_all(encode_line(&response).as_bytes())?;
        writer.flush()?;
    }
    Ok(())
}
