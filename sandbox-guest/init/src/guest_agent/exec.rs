//! Exec sessions for an already-booted Linux VM.
//!
//! The process lifecycle matches the sandbox init's protocol contract, but a
//! normal service owns and waits for its own child instead of delegating reaping
//! to PID 1. Commands run as the daemon's user (root in the systemd unit), in
//! `/` unless the request names a working directory, with request environment
//! entries merged over the service environment.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use nix::pty::{openpty, Winsize};
use nix::sys::signal::{killpg, Signal};
use nix::unistd::{setsid, Pid};

use strato_sandbox_init::protocol::{
    decode_base64, decode_request, encode_base64, encode_line, read_request_line, Request,
    Response, DEFAULT_EXEC_COLS, DEFAULT_EXEC_ROWS, DEFAULT_EXEC_TTY,
};

nix::ioctl_write_int_bad!(tiocsctty, libc::TIOCSCTTY);
nix::ioctl_write_ptr_bad!(tiocswinsz, libc::TIOCSWINSZ, Winsize);

pub struct ExecRequest {
    pub argv: Vec<String>,
    pub env: Option<BTreeMap<String, String>>,
    pub cwd: Option<String>,
    pub tty: Option<bool>,
    pub rows: Option<u16>,
    pub cols: Option<u16>,
}

pub fn run_exec_session(
    reader: BufReader<File>,
    writer: File,
    request: ExecRequest,
    nonce: String,
) {
    let writer = Arc::new(Mutex::new(writer));
    if let Err(message) = session(reader, &writer, request, &nonce) {
        eprintln!("[strato-guest-agent] exec session failed: {message}");
        send_response(&writer, &Response::Error { nonce, message });
    }
}

fn session(
    mut reader: BufReader<File>,
    writer: &Arc<Mutex<File>>,
    request: ExecRequest,
    nonce: &str,
) -> Result<(), String> {
    let Some((program, arguments)) = request.argv.split_first() else {
        return Err("exec argv must not be empty".to_string());
    };
    validate_environment(request.env.as_ref())?;

    let tty = request.tty.unwrap_or(DEFAULT_EXEC_TTY);
    let rows = request.rows.unwrap_or(DEFAULT_EXEC_ROWS);
    let cols = request.cols.unwrap_or(DEFAULT_EXEC_COLS);
    let cwd = request
        .cwd
        .as_deref()
        .filter(|path| !path.is_empty())
        .unwrap_or("/");

    let mut command = Command::new(program);
    command.args(arguments).current_dir(cwd);
    if let Some(environment) = request.env.as_ref() {
        command.envs(environment);
    }

    let mut pty_master: Option<OwnedFd> = None;
    let mut pty_master_read: Option<OwnedFd> = None;
    let mut pty_master_write: Option<OwnedFd> = None;
    if tty {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let pty = openpty(Some(&winsize), None::<&nix::sys::termios::Termios>)
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
        command
            .stdin(Stdio::from(stdin_slave))
            .stdout(Stdio::from(stdout_slave))
            .stderr(Stdio::from(pty.slave));
        unsafe {
            command.pre_exec(|| {
                setsid().map_err(std::io::Error::from)?;
                // SAFETY: stdin is the PTY slave in a fresh session that has no
                // controlling terminal yet.
                tiocsctty(0, 0).map_err(std::io::Error::from)?;
                Ok(())
            });
        }
    } else {
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
    }

    let mut child = command
        .spawn()
        .map_err(|e| format!("spawn {program}: {e}"))?;
    drop(command);
    let pid = child.id() as i32;

    if !send_response(
        writer,
        &Response::ExecStarted {
            nonce: nonce.to_string(),
        },
    ) {
        kill_group(pid);
        let _ = child.wait();
        return Ok(());
    }

    let exited = Arc::new(AtomicBool::new(false));
    let mut pumps = Vec::new();
    let stdin_sink: Option<Box<dyn Write + Send>>;
    if tty {
        if let Some(read_half) = pty_master_read.take() {
            pumps.extend(spawn_output_pump(
                "guest-exec-pty-out",
                File::from(read_half),
                "stdout",
                Arc::clone(writer),
                nonce.to_string(),
            ));
        }
        stdin_sink = pty_master_write
            .take()
            .map(|fd| Box::new(File::from(fd)) as Box<dyn Write + Send>);
    } else {
        stdin_sink = child
            .stdin
            .take()
            .map(|pipe| Box::new(pipe) as Box<dyn Write + Send>);
        if let Some(stdout) = child.stdout.take() {
            pumps.extend(spawn_output_pump(
                "guest-exec-stdout",
                stdout,
                "stdout",
                Arc::clone(writer),
                nonce.to_string(),
            ));
        }
        if let Some(stderr) = child.stderr.take() {
            pumps.extend(spawn_output_pump(
                "guest-exec-stderr",
                stderr,
                "stderr",
                Arc::clone(writer),
                nonce.to_string(),
            ));
        }
    }

    let mut stdin_tx = stdin_sink.and_then(spawn_stdin_writer);
    if let Err(e) = spawn_exit_waiter(
        child,
        pumps,
        Arc::clone(&exited),
        Arc::clone(writer),
        nonce.to_string(),
    ) {
        kill_group(pid);
        reap_pid(pid);
        return Err(e);
    }

    let mut line = String::new();
    loop {
        match read_request_line(&mut reader, &mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                eprintln!("[strato-guest-agent] exec input ended: {e}");
                break;
            }
        }
        if line.trim().is_empty() {
            continue;
        }
        match decode_request(&line) {
            Ok(Request::Stdin { data }) => match decode_base64(&data) {
                Ok(bytes) => {
                    if let Some(sender) = stdin_tx.as_ref() {
                        if sender.send(bytes).is_err() {
                            stdin_tx = None;
                        }
                    }
                }
                Err(e) => eprintln!("[strato-guest-agent] exec stdin: bad base64: {e}"),
            },
            Ok(Request::StdinEof) => stdin_tx = None,
            Ok(Request::Resize { rows, cols }) => {
                if let Some(master) = &pty_master {
                    let winsize = Winsize {
                        ws_row: rows,
                        ws_col: cols,
                        ws_xpixel: 0,
                        ws_ypixel: 0,
                    };
                    if let Err(e) = unsafe { tiocswinsz(master.as_raw_fd(), &winsize) } {
                        eprintln!("[strato-guest-agent] exec resize: {e}");
                    }
                }
            }
            Ok(_) => eprintln!(
                "[strato-guest-agent] request is not valid within an exec session; ignoring"
            ),
            Err(e) => eprintln!("[strato-guest-agent] undecodable exec request: {e}"),
        }
    }

    if !exited.load(Ordering::SeqCst) {
        kill_group(pid);
    }
    Ok(())
}

/// Reject values that `Command::envs` cannot represent before it can panic in
/// this root-running daemon.
fn validate_environment(environment: Option<&BTreeMap<String, String>>) -> Result<(), String> {
    let Some(environment) = environment else {
        return Ok(());
    };
    for (key, value) in environment {
        if key.is_empty() || key.contains('=') || key.contains('\0') {
            return Err(format!("invalid environment variable name {key:?}"));
        }
        if value.contains('\0') {
            return Err(format!("environment variable {key:?} contains NUL"));
        }
    }
    Ok(())
}

fn spawn_stdin_writer(mut sink: Box<dyn Write + Send>) -> Option<Sender<Vec<u8>>> {
    let (sender, receiver) = std::sync::mpsc::channel::<Vec<u8>>();
    match std::thread::Builder::new()
        .name("guest-exec-stdin".to_string())
        .spawn(move || {
            for bytes in receiver {
                if let Err(e) = sink.write_all(&bytes).and_then(|_| sink.flush()) {
                    eprintln!("[strato-guest-agent] exec stdin write: {e}");
                    return;
                }
            }
        }) {
        Ok(_) => Some(sender),
        Err(e) => {
            eprintln!("[strato-guest-agent] spawn stdin writer: {e}");
            None
        }
    }
}

fn spawn_output_pump<R: Read + Send + 'static>(
    name: &'static str,
    mut source: R,
    stream: &'static str,
    writer: Arc<Mutex<File>>,
    nonce: String,
) -> Option<JoinHandle<()>> {
    match std::thread::Builder::new()
        .name(name.to_string())
        .spawn(move || {
            let mut buffer = [0u8; 8192];
            loop {
                match source.read(&mut buffer) {
                    Ok(0) => return,
                    Ok(count) => {
                        if !send_response(
                            &writer,
                            &Response::Output {
                                nonce: nonce.clone(),
                                stream: stream.to_string(),
                                data: encode_base64(&buffer[..count]),
                            },
                        ) {
                            return;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    // Linux returns EIO from a PTY master after its final slave
                    // closes. Other errors also end just this output stream.
                    Err(_) => return,
                }
            }
        }) {
        Ok(handle) => Some(handle),
        Err(e) => {
            eprintln!("[strato-guest-agent] spawn {name}: {e}");
            None
        }
    }
}

fn spawn_exit_waiter(
    mut child: Child,
    pumps: Vec<JoinHandle<()>>,
    exited: Arc<AtomicBool>,
    writer: Arc<Mutex<File>>,
    nonce: String,
) -> Result<(), String> {
    std::thread::Builder::new()
        .name("guest-exec-wait".to_string())
        .spawn(move || {
            let exit_code = match child.wait() {
                Ok(status) => exit_status_code(status),
                Err(e) => {
                    eprintln!("[strato-guest-agent] wait for exec child: {e}");
                    -1
                }
            };
            for pump in pumps {
                let _ = pump.join();
            }
            exited.store(true, Ordering::SeqCst);
            send_response(&writer, &Response::ExecExit { nonce, exit_code });
            shutdown_connection(&writer);
        })
        .map(|_| ())
        .map_err(|e| format!("spawn exit waiter: {e}"))
}

fn exit_status_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;

    status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(-1)
}

fn send_response(writer: &Mutex<File>, response: &Response) -> bool {
    let line = encode_line(response);
    let mut writer = writer.lock().expect("exec writer poisoned");
    writer
        .write_all(line.as_bytes())
        .and_then(|_| writer.flush())
        .is_ok()
}

fn kill_group(pid: i32) {
    let _ = killpg(Pid::from_raw(pid), Signal::SIGKILL);
}

/// Reap a child after its `Child` handle was dropped with a failed waiter-thread
/// spawn. This path is nearly unreachable, but a long-running service must not
/// leave a zombie behind when resources are already constrained.
fn reap_pid(pid: i32) {
    let mut status = 0;
    loop {
        let result = unsafe { libc::waitpid(pid, &mut status, 0) };
        if result >= 0 {
            return;
        }
        if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return;
        }
    }
}

fn shutdown_connection(writer: &Mutex<File>) {
    let writer = writer.lock().expect("exec writer poisoned");
    unsafe {
        libc::shutdown(writer.as_raw_fd(), libc::SHUT_RDWR);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn environment_validation_prevents_command_panics() {
        let mut environment = BTreeMap::new();
        environment.insert("GOOD".into(), "value".into());
        assert!(validate_environment(Some(&environment)).is_ok());

        for bad_name in ["", "A=B", "A\0B"] {
            let mut environment = BTreeMap::new();
            environment.insert(bad_name.into(), "value".into());
            assert!(validate_environment(Some(&environment)).is_err());
        }
        environment.clear();
        environment.insert("GOOD".into(), "bad\0value".into());
        assert!(validate_environment(Some(&environment)).is_err());
    }

    #[test]
    fn signal_exit_uses_shell_convention() {
        use std::os::unix::process::ExitStatusExt;

        assert_eq!(exit_status_code(std::process::ExitStatus::from_raw(9)), 137);
    }
}
