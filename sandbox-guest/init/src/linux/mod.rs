//! Linux PID-1 orchestration for the sandbox guest init (issues #419, #423).
//!
//! Sequence: bring up pseudo-filesystems → read the config drive → resolve the
//! process to run → mount and switch onto the container rootfs → start the
//! vsock agent → launch the workload (stdio captured via pipes) → reap every
//! child forever, routing exec exit codes and serving status over vsock.

mod exec;
mod logs;
mod mounts;
mod reaper;
mod vsock;

use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};
use std::sync::{Arc, Mutex};

use nix::sys::reboot::{reboot, RebootMode};
use nix::unistd::{setgid, setgroups, setuid, Gid, Pid, Uid};

use strato_sandbox_init::config::{GuestConfig, ResolvedProcess};
use strato_sandbox_init::logbuf::LogBuffer;
use strato_sandbox_init::protocol::WorkloadState;

use reaper::ChildRegistry;
use vsock::{GuestState, SharedStatus, Status};

/// Default config-drive device when the kernel command line does not name one.
const DEFAULT_CONFIG_DEVICE: &str = "/dev/vdb";

/// Entry point. Never returns on the happy path — PID 1 reaps children
/// forever while the vsock agent keeps serving status, exec sessions, and log
/// streams until the host tears the microVM down.
pub fn run() -> ExitCode {
    match bringup() {
        Ok(()) => {
            // Unreachable: bringup ends in the forever-running reaper. Kept
            // so the signature is honest if that ever changes.
            ExitCode::SUCCESS
        }
        Err(e) => fatal(&format!("sandbox init failed: {e}")),
    }
}

fn bringup() -> Result<(), Box<dyn std::error::Error>> {
    mounts::mount_early()?;

    let config_device =
        config_device_from_cmdline().unwrap_or_else(|| DEFAULT_CONFIG_DEVICE.to_string());
    let raw = mounts::read_config_drive(&config_device)?;
    let cfg =
        GuestConfig::from_config_drive(&raw).map_err(|e| format!("parse config drive: {e}"))?;
    // Resolve before touching disks so a bad config fails fast. A warm-start
    // template (issue #426) has no workload of its own — the real process
    // arrives with the post-restore `launch` request — so it parks with a
    // placeholder root context instead (exec sessions on a held template,
    // should the host ever open one, run as root at `/`).
    let process = if cfg.warm_hold {
        ResolvedProcess {
            argv: Vec::new(),
            env: cfg.image_config.env.clone(),
            cwd: "/".to_string(),
            uid: 0,
            gid: 0,
        }
    } else {
        cfg.resolve_process()?
    };

    mounts::mount_container_rootfs(&cfg.rootfs)?;
    mounts::switch_into_rootfs()?;
    mounts::mount_container_api()?;

    let status: SharedStatus = Arc::new(Mutex::new(Status {
        sandbox_id: cfg.sandbox_id.clone(),
        nonce: cfg.identity_nonce.clone(),
        state: if cfg.warm_hold {
            WorkloadState::Held
        } else {
            WorkloadState::Starting
        },
        exit_code: None,
    }));
    let logs = Arc::new(LogBuffer::new());
    let children = Arc::new(ChildRegistry::new());
    let workload_pid: reaper::SharedWorkloadPid = Arc::new(Mutex::new(None));

    // The vsock agent runs for the life of the microVM. A bind failure is
    // logged and non-fatal — the workload still runs, just without a control
    // channel — so we do not propagate the error. (A held template without a
    // control channel is useless but harmless: it can never launch, and the
    // host's health check fails the template boot.)
    let state = Arc::new(GuestState {
        status: status.clone(),
        process: Mutex::new(process.clone()),
        logs: logs.clone(),
        children: children.clone(),
        workload_pid: workload_pid.clone(),
    });
    let vsock_port = cfg.vsock_port;
    {
        let state = state.clone();
        std::thread::Builder::new()
            .name("vsock-agent".into())
            .spawn(move || {
                if let Err(e) = vsock::serve(vsock_port, state) {
                    eprintln!("[sandbox-init] vsock agent stopped: {e}");
                }
            })?;
    }

    if !cfg.warm_hold {
        launch_workload(&state, process)?;
    }

    // PID 1's forever duty: reap every child, route exec exit codes, and keep
    // the workload's exit status available until the host powers us off.
    reaper::reap_forever(&workload_pid, &status, &children)
}

/// Spawn the workload and publish it to the shared state: the resolved
/// process becomes the exec-session default context, the pid becomes the
/// reaper's workload pid, and the status moves to `Running`. Shared between
/// the cold-boot path and the warm-start `launch` request (issue #426),
/// which calls it from a vsock connection thread.
pub(crate) fn launch_workload(state: &GuestState, process: ResolvedProcess) -> Result<(), String> {
    let pid = spawn_workload(&process, &state.logs).map_err(|e| e.to_string())?;
    *state.process.lock().expect("process poisoned") = process;
    *state.workload_pid.lock().expect("workload pid poisoned") = Some(pid);
    state.children.notify_spawned();

    // The reaper only learned the workload pid just now; if the process
    // already exited and was reaped as an unknown pid, claim that exit —
    // otherwise mark the workload running (unless the reaper beat us to the
    // exit in the meantime, which record-once semantics respect).
    if let Some(code) = state.children.claim_unclaimed(pid.as_raw()) {
        reaper::record_workload_exit_once(&state.status, code);
    } else {
        let mut s = state.status.lock().expect("status poisoned");
        if s.state != WorkloadState::Exited {
            s.state = WorkloadState::Running;
        }
    }
    Ok(())
}

/// Launch the container workload as a child process with the resolved
/// environment, working directory, and credentials. stdin is `/dev/null`;
/// stdout/stderr are pipes whose pump threads mirror every chunk to the
/// console (preserving serial-log debuggability, partial lines included) and
/// append it to the log ring buffer (issue #423). Returns its pid.
fn spawn_workload(
    process: &ResolvedProcess,
    logs: &Arc<LogBuffer>,
) -> Result<Pid, Box<dyn std::error::Error>> {
    let (program, args) = process.argv.split_first().ok_or("empty argv")?;

    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(&process.cwd)
        .env_clear()
        .envs(
            process
                .env
                .iter()
                .filter_map(|kv: &String| kv.split_once('=')),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let uid = process.uid;
    let gid = process.gid;
    // Full credential drop inside pre_exec; see [`drop_credentials`] for why
    // Command::uid/gid must not be used here.
    unsafe {
        cmd.pre_exec(move || drop_credentials(uid, gid));
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("exec workload {program}: {e}"))?;
    // Register BOTH stdio writers before the first pump can possibly finish,
    // so a fast-EOFing stream cannot transiently close the buffer while the
    // other pump is still being set up. The buffer closing (both pumps done)
    // is what lets a log follower send `log_eof` to the host.
    logs.register_writer();
    logs.register_writer();
    match child.stdout.take() {
        Some(stdout) => logs::spawn_workload_pump(
            "workload-stdout",
            stdout,
            libc::STDOUT_FILENO,
            "stdout",
            logs.clone(),
        ),
        None => logs.writer_done(),
    }
    match child.stderr.take() {
        Some(stderr) => logs::spawn_workload_pump(
            "workload-stderr",
            stderr,
            libc::STDERR_FILENO,
            "stderr",
            logs.clone(),
        ),
        None => logs.writer_done(),
    }
    Ok(Pid::from_raw(child.id() as i32))
}

/// Drop to the workload's credentials: supplementary groups reduce to just
/// the primary gid, then setgid, then setuid — the classic order, run inside
/// a pre_exec closure while the child is still privileged.
///
/// `Command::uid`/`gid` are deliberately NOT used: std applies them BEFORE
/// pre_exec closures run, so a setgroups in pre_exec would fail EPERM for any
/// non-root uid — and `CommandExt::groups`, which would let std order the
/// calls correctly, is still unstable (rust-lang/rust#90747).
///
/// Async-signal-safe: three raw syscalls, no allocation.
pub(crate) fn drop_credentials(uid: u32, gid: u32) -> std::io::Result<()> {
    let gid = Gid::from_raw(gid);
    setgroups(&[gid]).map_err(std::io::Error::from)?;
    setgid(gid).map_err(std::io::Error::from)?;
    setuid(Uid::from_raw(uid)).map_err(std::io::Error::from)?;
    Ok(())
}

/// Parse `strato.config=<device>` from the kernel command line, if present.
fn config_device_from_cmdline() -> Option<String> {
    let cmdline = std::fs::read_to_string("/proc/cmdline").ok()?;
    cmdline
        .split_whitespace()
        .find_map(|tok| tok.strip_prefix("strato.config=").map(|v| v.to_string()))
}

/// Print a fatal message to the console and power the microVM off, rather than
/// letting PID 1 exit (which would panic the kernel and hang the guest).
fn fatal(message: &str) -> ! {
    eprintln!("[sandbox-init] FATAL: {message}");
    // Best effort; if the reboot syscall itself fails there is nothing left to
    // do but loop so the serial log preserves the message.
    let _ = reboot(RebootMode::RB_POWER_OFF);
    loop {
        std::thread::park();
    }
}
