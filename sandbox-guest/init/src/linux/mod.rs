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
use nix::unistd::{setgroups, Gid, Pid};

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
    let process = cfg.resolve_process()?;

    mounts::mount_container_rootfs(&cfg.rootfs)?;
    mounts::switch_into_rootfs()?;
    mounts::mount_container_api()?;

    let status: SharedStatus = Arc::new(Mutex::new(Status {
        sandbox_id: cfg.sandbox_id.clone(),
        nonce: cfg.identity_nonce.clone(),
        state: WorkloadState::Starting,
        exit_code: None,
    }));
    let logs = Arc::new(LogBuffer::new());
    let children = Arc::new(ChildRegistry::new());

    // The vsock agent runs for the life of the microVM. A bind failure is
    // logged and non-fatal — the workload still runs, just without a control
    // channel — so we do not propagate the error.
    let state = Arc::new(GuestState {
        status: status.clone(),
        process: process.clone(),
        logs: logs.clone(),
        children: children.clone(),
    });
    let vsock_port = cfg.vsock_port;
    std::thread::Builder::new()
        .name("vsock-agent".into())
        .spawn(move || {
            if let Err(e) = vsock::serve(vsock_port, state) {
                eprintln!("[sandbox-init] vsock agent stopped: {e}");
            }
        })?;

    let workload_pid = spawn_workload(&process, &logs)?;
    children.notify_spawned();
    {
        let mut s = status.lock().expect("status poisoned");
        s.state = WorkloadState::Running;
    }

    // PID 1's forever duty: reap every child, route exec exit codes, and keep
    // the workload's exit status available until the host powers us off.
    reaper::reap_forever(workload_pid, &status, &children)
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
    // Drop supplementary groups to just the primary gid before the runtime
    // applies uid/gid. Runs in the child, still privileged, pre-exec.
    unsafe {
        cmd.pre_exec(move || setgroups(&[Gid::from_raw(gid)]).map_err(std::io::Error::from));
    }
    cmd.gid(gid).uid(uid);

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("exec workload {program}: {e}"))?;
    if let Some(stdout) = child.stdout.take() {
        logs::spawn_workload_pump(
            "workload-stdout",
            stdout,
            libc::STDOUT_FILENO,
            "stdout",
            logs.clone(),
        );
    }
    if let Some(stderr) = child.stderr.take() {
        logs::spawn_workload_pump(
            "workload-stderr",
            stderr,
            libc::STDERR_FILENO,
            "stderr",
            logs.clone(),
        );
    }
    Ok(Pid::from_raw(child.id() as i32))
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
