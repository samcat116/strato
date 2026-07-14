//! Workload stdio capture and the vsock log follow stream (issue #423,
//! Linux only).
//!
//! The workload's stdout/stderr are pipes (no longer inherited from the
//! console). One pump thread per stream reads chunks and does two things with
//! every one of them:
//!
//! 1. **mirrors the raw bytes to the init's own console fd** — the serial log
//!    stays a faithful debugging record, including partial lines;
//! 2. **appends them to the shared [`LogBuffer`] ring** so the host can fetch
//!    and follow them over vsock.
//!
//! A `stream_logs` connection replays retained records from `since_seq`
//! (evicted ones are silently skipped) and then follows new output forever.
//! The host sends nothing after the initial request, so readability on the
//! socket means hangup (or stray input we drain and ignore) — a quiet stream
//! probes for that between condvar waits instead of blocking forever on a
//! departed host.

use std::fs::File;
use std::io::{BufReader, Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::Arc;
use std::time::Duration;

use strato_sandbox_init::logbuf::LogBuffer;
use strato_sandbox_init::protocol::{encode_base64, encode_line, Response};

/// How long a quiet follow stream waits on the ring buffer between
/// connection-liveness probes.
const FOLLOW_IDLE_PROBE: Duration = Duration::from_millis(500);

/// Spawn a pump thread mirroring one workload output pipe to the console and
/// the log ring buffer. A thread-spawn failure is logged and swallowed — the
/// workload keeps running, just without capture on that stream.
///
/// The caller registered this pump as a buffer writer (see `register_writer`);
/// the pump marks it done when the pipe hits EOF — or right here when the
/// thread never starts — so the buffer can close and followers can signal
/// end-of-stream.
pub fn spawn_workload_pump(
    name: &'static str,
    src: impl Read + Send + 'static,
    console_fd: RawFd,
    stream: &'static str,
    logs: Arc<LogBuffer>,
) {
    let pump_logs = logs.clone();
    let spawned = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(move || {
            pump_workload_stream(src, console_fd, stream, &pump_logs);
            pump_logs.writer_done();
        });
    if let Err(e) = spawned {
        // Accepted tradeoff: the pipe read end drops here, so the workload can
        // die of SIGPIPE (exit 141) on its next write to this stream — which
        // v1's console inheritance could not. A visible exit beats a silent
        // stall, and thread-spawn failure in this init is close to unreachable.
        eprintln!("[sandbox-init] spawn {name} pump: {e}");
        logs.writer_done();
    }
}

fn pump_workload_stream(
    mut src: impl Read,
    console_fd: RawFd,
    stream: &'static str,
    logs: &LogBuffer,
) {
    let mut buf = [0u8; 8192];
    loop {
        match src.read(&mut buf) {
            Ok(0) => return, // workload closed its end
            Ok(n) => {
                mirror_to_console(console_fd, &buf[..n]);
                logs.append(stream, &buf[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// Raw, unbuffered write to the init's own console fd so partial lines and
/// arbitrary bytes land in the serial log verbatim. Best effort: a console
/// write error must never stall workload output capture.
fn mirror_to_console(fd: RawFd, data: &[u8]) {
    let mut rest = data;
    while !rest.is_empty() {
        // SAFETY: plain write(2) on the init's own stdout/stderr fd, which
        // stays open for the life of the process.
        let n = unsafe { libc::write(fd, rest.as_ptr() as *const libc::c_void, rest.len()) };
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        if n == 0 {
            return;
        }
        rest = &rest[n as usize..];
    }
}

/// Serve one `stream_logs` connection: replay retained records with
/// `seq >= since_seq`, then follow new output until the host disconnects.
/// `reader` is kept only to probe the connection for hangup — the host sends
/// nothing after the initial request.
pub fn run_follow_stream(
    reader: BufReader<File>,
    mut writer: File,
    since_seq: u64,
    logs: &LogBuffer,
) {
    let probe_fd = reader.get_ref().as_raw_fd();
    let mut next = since_seq.max(1);
    loop {
        let records = logs.wait_since(next, FOLLOW_IDLE_PROBE);
        if records.is_empty() {
            if logs.is_closed() {
                // Every pipe hit EOF and everything retained was delivered:
                // tell the host the stream is complete so it can flush a
                // partial final line, then end the connection.
                let _ = writer.write_all(encode_line(&Response::LogEof).as_bytes());
                return;
            }
            if peer_hung_up(probe_fd) {
                return;
            }
            continue;
        }
        for record in &records {
            let line = encode_line(&Response::Log {
                seq: record.seq,
                stream: record.stream.to_string(),
                data: encode_base64(&record.data),
            });
            if writer.write_all(line.as_bytes()).is_err() {
                return; // host gone
            }
        }
        if let Some(last) = records.last() {
            next = last.seq + 1;
        }
    }
}

/// Zero-timeout poll for hangup on the follow stream's connection.
fn peer_hung_up(fd: RawFd) -> bool {
    let mut pfd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: poll(2) on our own connection fd with a zero timeout.
    let rc = unsafe { libc::poll(&mut pfd, 1, 0) };
    if rc <= 0 {
        return false; // nothing pending or a transient error: assume alive
    }
    if pfd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
        return true;
    }
    if pfd.revents & libc::POLLIN != 0 {
        let mut scratch = [0u8; 256];
        // SAFETY: read(2) into a local buffer; POLLIN guarantees no blocking.
        let n = unsafe { libc::read(fd, scratch.as_mut_ptr() as *mut libc::c_void, scratch.len()) };
        if n > 0 {
            return false; // unexpected input; drain and ignore
        }
        if n == 0 {
            return true; // orderly EOF: host closed
        }
        return !matches!(
            std::io::Error::last_os_error().kind(),
            std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
        );
    }
    false
}
