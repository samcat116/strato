//! Exec sessions over vsock (issue #423, Linux only).
//!
//! A connection whose first request is `exec` becomes a dedicated session for
//! one child process, run in the workload's context: its resolved env (with
//! the request's env merged over it), its cwd (unless the request overrides
//! it), and its uid/gid — no credential overrides in this phase.
//!
//! Two spawn shapes:
//!
//! * **tty**: a PTY pair (`openpty` with the requested winsize). The child
//!   gets the slave as stdin/stdout/stderr in a **new session** (`setsid` +
//!   `TIOCSCTTY`), all output is reported as stream `"stdout"`, and `resize`
//!   maps to `TIOCSWINSZ` on the master.
//! * **non-tty**: three pipes, the child in its **own process group**, with
//!   stdout and stderr reported separately. `resize` is ignored.
//!
//! Lifecycle: `exec_started` after a successful spawn (an `error` line and
//! connection close otherwise) → `output` chunks pumped by reader threads →
//! interleaved host `resize` applied by the connection thread and
//! `stdin`/`stdin_eof` forwarded to a dedicated writer thread (a child that
//! never drains its stdin must not block the connection loop, or it would
//! never observe host disconnect) → child reaped **by PID 1's central reaper**
//! (delivered through the [`ChildRegistry`]) → output pumps drained → one
//! terminal `exec_exit` → connection shutdown. If the host closes the
//! connection before `exec_exit`, the whole process group is SIGKILLed.
//!
//! Responses are written by several threads (output pumps, the exit waiter,
//! the connection thread), so the write half sits behind a mutex and every
//! response goes out as one full line under the lock.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use nix::pty::{openpty, Winsize};
use nix::sys::signal::{killpg, Signal};
use nix::unistd::{setsid, Pid};

use strato_sandbox_init::config::merge_env;
use strato_sandbox_init::protocol::{
    decode_base64, decode_request, encode_line, Request, Response, DEFAULT_EXEC_COLS,
    DEFAULT_EXEC_ROWS, DEFAULT_EXEC_TTY,
};

use super::vsock::GuestState;

nix::ioctl_write_int_bad!(tiocsctty, libc::TIOCSCTTY);
nix::ioctl_write_ptr_bad!(tiocswinsz, libc::TIOCSWINSZ, Winsize);

/// The decoded fields of a [`Request::Exec`], handed over by the vsock
/// connection dispatcher.
pub struct ExecRequest {
    pub argv: Vec<String>,
    pub env: Option<BTreeMap<String, String>>,
    pub cwd: Option<String>,
    pub tty: Option<bool>,
    pub rows: Option<u16>,
    pub cols: Option<u16>,
}

/// Run one exec session on an established vsock connection. Consumes the
/// connection; never panics — failures are reported as `error` lines (before
/// spawn) or logged to the console (after).
pub fn run_exec_session(
    reader: BufReader<File>,
    writer: File,
    req: ExecRequest,
    state: &GuestState,
) {
    let writer = Arc::new(Mutex::new(writer));
    if let Err(message) = session(reader, &writer, req, state) {
        eprintln!("[sandbox-init] exec session failed: {message}");
        send_response(&writer, &Response::Error { message });
    }
}

/// Everything up to and including the host-input loop. `Err` means the spawn
/// never happened (or the PTY could not be set up) and the caller should send
/// an `error` line.
fn session(
    mut reader: BufReader<File>,
    writer: &Arc<Mutex<File>>,
    req: ExecRequest,
    state: &GuestState,
) -> Result<(), String> {
    let Some((program, args)) = req.argv.split_first() else {
        return Err("exec argv must not be empty".to_string());
    };
    let tty = req.tty.unwrap_or(DEFAULT_EXEC_TTY);
    let rows = req.rows.unwrap_or(DEFAULT_EXEC_ROWS);
    let cols = req.cols.unwrap_or(DEFAULT_EXEC_COLS);

    // Workload context: request env merges OVER the resolved env; cwd
    // defaults to the workload's; uid/gid are the workload's, always.
    // Snapshot under the lock — a warm-start `launch` may replace the
    // process concurrently, and a consistent pre- or post-launch view is
    // all a session needs.
    let workload = state.process.lock().expect("process poisoned").clone();
    let env = merge_env(&workload.env, &req.env.clone().unwrap_or_default());
    let cwd = req
        .cwd
        .clone()
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| workload.cwd.clone());
    let uid = workload.uid;
    let gid = workload.gid;

    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(&cwd)
        .env_clear()
        .envs(env.iter().filter_map(|kv: &String| kv.split_once('=')));

    // PTY handles (tty mode). Dup the master up front so post-spawn failure
    // modes stay trivial: one dup feeds the output pump, one is the stdin
    // sink, and the original serves TIOCSWINSZ.
    let mut pty_master: Option<OwnedFd> = None;
    let mut pty_master_read: Option<OwnedFd> = None;
    let mut pty_master_write: Option<OwnedFd> = None;
    if tty {
        let ws = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let pty = openpty(Some(&ws), None::<&nix::sys::termios::Termios>)
            .map_err(|e| format!("openpty: {e}"))?;
        pty_master_read = Some(
            pty.master
                .try_clone()
                .map_err(|e| format!("dup pty master: {e}"))?,
        );
        pty_master_write = Some(
            pty.master
                .try_clone()
                .map_err(|e| format!("dup pty master: {e}"))?,
        );
        pty_master = Some(pty.master);

        let stdin_slave = pty
            .slave
            .try_clone()
            .map_err(|e| format!("dup pty slave: {e}"))?;
        let stdout_slave = pty
            .slave
            .try_clone()
            .map_err(|e| format!("dup pty slave: {e}"))?;
        cmd.stdin(Stdio::from(stdin_slave))
            .stdout(Stdio::from(stdout_slave))
            .stderr(Stdio::from(pty.slave));

        // New session with the PTY slave as controlling terminal, then the
        // same full credential drop the workload spawn does (see
        // [`super::drop_credentials`] for why not Command::uid/gid). Runs in
        // the child, pre-exec.
        unsafe {
            cmd.pre_exec(move || {
                setsid().map_err(std::io::Error::from)?;
                // SAFETY (of the ioctl): fd 0 is the PTY slave, and this
                // fresh session has no controlling terminal yet.
                tiocsctty(0, 0).map_err(std::io::Error::from)?;
                super::drop_credentials(uid, gid)
            });
        }
    } else {
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // Own process group so an early host disconnect can SIGKILL the
        // whole tree without touching the workload.
        cmd.process_group(0);
        unsafe {
            cmd.pre_exec(move || super::drop_credentials(uid, gid));
        }
    }

    let mut child = cmd.spawn().map_err(|e| format!("spawn {program}: {e}"))?;
    // Drop the Command now: it still holds the PTY slave Stdio handles, and
    // the master would never report EIO (child gone) while they linger here.
    drop(cmd);

    let pid = child.id() as i32;
    // Register with the central reaper before anything else; the registry's
    // unclaimed map covers an exit racing this registration.
    let exit_rx = state.children.register(pid);

    if !send_response(writer, &Response::ExecStarted) {
        // Host vanished between request and spawn; don't leave the child
        // running unattended.
        kill_group(pid);
        return Ok(());
    }

    // Output pumps and the stdin sink.
    let exited = Arc::new(AtomicBool::new(false));
    let mut pumps: Vec<JoinHandle<()>> = Vec::new();
    let stdin_sink: Option<Box<dyn Write + Send>>;
    if tty {
        if let Some(read_half) = pty_master_read.take() {
            pumps.extend(spawn_output_pump(
                "exec-pty-out",
                File::from(read_half),
                "stdout",
                writer.clone(),
            ));
        }
        stdin_sink = pty_master_write
            .take()
            .map(|fd| Box::new(File::from(fd)) as Box<dyn Write + Send>);
    } else {
        stdin_sink = child
            .stdin
            .take()
            .map(|s| Box::new(s) as Box<dyn Write + Send>);
        if let Some(out) = child.stdout.take() {
            pumps.extend(spawn_output_pump(
                "exec-stdout",
                out,
                "stdout",
                writer.clone(),
            ));
        }
        if let Some(err) = child.stderr.take() {
            pumps.extend(spawn_output_pump(
                "exec-stderr",
                err,
                "stderr",
                writer.clone(),
            ));
        }
    }
    // The Child handle has served its purpose (pipes + pid); dropping it does
    // not kill or wait — reaping is the central reaper's job.
    drop(child);

    // Stdin goes through a dedicated writer thread: a child that never drains
    // its stdin would otherwise block write_all on the connection thread once
    // the pipe fills, and that thread must keep reading to observe host
    // disconnect (and reach kill_group below). The channel is unbounded, which
    // is fine — input is interactive and host-paced.
    let mut stdin_tx = stdin_sink.and_then(spawn_stdin_writer);

    spawn_exit_waiter(exit_rx, pumps, exited.clone(), writer.clone());

    // Host-input loop: stdin/stdin_eof/resize until the host closes the
    // connection or the exit waiter shuts the socket down after exec_exit.
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
        if line.trim().is_empty() {
            continue;
        }
        match decode_request(&line) {
            Ok(Request::Stdin { data }) => match decode_base64(&data) {
                Ok(bytes) => {
                    if let Some(tx) = stdin_tx.as_ref() {
                        // A send error means the writer thread died on a write
                        // error (already logged there); stop queueing.
                        if tx.send(bytes).is_err() {
                            stdin_tx = None;
                        }
                    }
                }
                Err(e) => eprintln!("[sandbox-init] exec stdin: bad base64: {e}"),
            },
            Ok(Request::StdinEof) => {
                // Dropping the sender lets the writer drain its queue, then
                // drop the sink. Pipe mode: that closes the child's stdin.
                // tty mode: only stops writes (per spec, a permitted no-op).
                stdin_tx = None;
            }
            Ok(Request::Resize { rows, cols }) => {
                if let Some(master) = &pty_master {
                    let ws = Winsize {
                        ws_row: rows,
                        ws_col: cols,
                        ws_xpixel: 0,
                        ws_ypixel: 0,
                    };
                    // SAFETY: TIOCSWINSZ on our own PTY master with a valid
                    // winsize struct.
                    if let Err(e) = unsafe { tiocswinsz(master.as_raw_fd(), &ws) } {
                        eprintln!("[sandbox-init] exec resize: {e}");
                    }
                }
            }
            Ok(_) => {
                eprintln!("[sandbox-init] exec session: request not valid mid-session; ignoring");
            }
            Err(e) => eprintln!("[sandbox-init] exec session: undecodable request: {e}"),
        }
    }

    // Connection over. If the child has not exited, the host went away early:
    // SIGKILL its whole process group (session and group leader == pid for
    // both spawn shapes).
    if !exited.load(Ordering::SeqCst) {
        kill_group(pid);
    }
    Ok(())
}

/// Spawn the dedicated stdin writer thread and hand back its sender. Dropping
/// the sender signals EOF: the thread drains the queue, then drops the sink
/// (closing the child's stdin in pipe mode). A write error is logged and ends
/// the thread — never the session; the sink drops with it. A thread-spawn
/// failure is logged and yields `None` (the session runs without stdin).
fn spawn_stdin_writer(mut sink: Box<dyn Write + Send>) -> Option<Sender<Vec<u8>>> {
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let spawned = std::thread::Builder::new()
        .name("exec-stdin".to_string())
        .spawn(move || {
            for bytes in rx {
                if let Err(e) = sink.write_all(&bytes).and_then(|_| sink.flush()) {
                    eprintln!("[sandbox-init] exec stdin write: {e}");
                    return;
                }
            }
        });
    match spawned {
        Ok(_) => Some(tx),
        Err(e) => {
            eprintln!("[sandbox-init] exec: spawn stdin writer: {e}");
            None
        }
    }
}

/// Pump one output source into base64 `output` lines. Returns the handle, or
/// nothing when the thread could not be spawned (logged; the child still runs
/// and exec_exit is still delivered, output on this stream is just lost).
fn spawn_output_pump<R: Read + Send + 'static>(
    name: &'static str,
    mut src: R,
    stream: &'static str,
    writer: Arc<Mutex<File>>,
) -> Option<JoinHandle<()>> {
    let spawned = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match src.read(&mut buf) {
                    Ok(0) => return,
                    Ok(n) => {
                        let resp = Response::Output {
                            stream: stream.to_string(),
                            data: strato_sandbox_init::protocol::encode_base64(&buf[..n]),
                        };
                        if !send_response(&writer, &resp) {
                            return; // host gone
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    // A PTY master read returns EIO once the last slave fd is
                    // closed (the child exited); either way this stream is over.
                    Err(_) => return,
                }
            }
        });
    match spawned {
        Ok(handle) => Some(handle),
        Err(e) => {
            eprintln!("[sandbox-init] exec: spawn {name} pump: {e}");
            None
        }
    }
}

/// Wait (off-thread) for the reaper to deliver the child's exit code, drain
/// the output pumps, then send the terminal `exec_exit` and shut the
/// connection down (which also unblocks the host-input loop).
fn spawn_exit_waiter(
    exit_rx: Receiver<i32>,
    pumps: Vec<JoinHandle<()>>,
    exited: Arc<AtomicBool>,
    writer: Arc<Mutex<File>>,
) {
    let spawned = std::thread::Builder::new()
        .name("exec-wait".to_string())
        .spawn(move || {
            // The registry keeps the sender until it delivers, so a recv error
            // cannot really happen; -1 keeps the session terminating regardless.
            let exit_code = exit_rx.recv().unwrap_or(-1);
            // exec_exit must come after all buffered output has been flushed.
            for pump in pumps {
                let _ = pump.join();
            }
            exited.store(true, Ordering::SeqCst);
            send_response(&writer, &Response::ExecExit { exit_code });
            shutdown_connection(&writer);
        });
    if let Err(e) = spawned {
        // Without the waiter the session cannot terminate cleanly; the host
        // will observe the missing exec_exit and tear the connection down.
        eprintln!("[sandbox-init] exec: spawn exit waiter: {e}");
    }
}

/// Write one response line under the write lock. Returns false when the host
/// is gone (callers stop pumping).
fn send_response(writer: &Mutex<File>, response: &Response) -> bool {
    let line = encode_line(response);
    let mut w = writer.lock().expect("exec writer poisoned");
    w.write_all(line.as_bytes()).and_then(|_| w.flush()).is_ok()
}

/// SIGKILL the exec child's process group. Best effort: the group may already
/// be gone.
fn kill_group(pid: i32) {
    let _ = killpg(Pid::from_raw(pid), Signal::SIGKILL);
}

/// Shut down both halves of the connection socket so every thread blocked on
/// it (notably the host-input loop) unblocks with EOF.
fn shutdown_connection(writer: &Mutex<File>) {
    let w = writer.lock().expect("exec writer poisoned");
    // SAFETY: shutdown(2) on our own connected socket fd.
    unsafe {
        libc::shutdown(w.as_raw_fd(), libc::SHUT_RDWR);
    }
}
