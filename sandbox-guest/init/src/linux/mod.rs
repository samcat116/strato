//! Linux PID-1 orchestration for the sandbox guest init (issue #419).
//!
//! Sequence: bring up pseudo-filesystems → read the config drive → resolve the
//! process to run → mount and switch onto the container rootfs → start the
//! vsock agent → launch the workload → reap zombies while serving status.

mod mounts;
mod vsock;

use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};
use std::sync::{Arc, Mutex};

use nix::sys::reboot::{reboot, RebootMode};
use nix::sys::wait::{waitpid, WaitStatus};
use nix::unistd::{setgroups, Gid, Pid};

use strato_sandbox_init::config::{GuestConfig, ResolvedProcess};
use strato_sandbox_init::protocol::WorkloadState;
use vsock::{SharedStatus, Status};

/// Default config-drive device when the kernel command line does not name one.
const DEFAULT_CONFIG_DEVICE: &str = "/dev/vdb";

/// Entry point. Never returns on the happy path — once the workload has run,
/// the init parks so the vsock agent keeps serving the exit status until the
/// host tears the microVM down.
pub fn run() -> ExitCode {
    match bringup() {
        Ok(()) => {
            // Unreachable: bringup parks forever after reaping. Kept so the
            // signature is honest if that ever changes.
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

    // The vsock agent runs for the life of the microVM. A bind failure is
    // logged and non-fatal — the workload still runs, just without a control
    // channel — so we do not propagate the error.
    let agent_status = status.clone();
    let vsock_port = cfg.vsock_port;
    std::thread::Builder::new()
        .name("vsock-agent".into())
        .spawn(move || {
            if let Err(e) = vsock::serve(vsock_port, agent_status) {
                eprintln!("[sandbox-init] vsock agent stopped: {e}");
            }
        })?;

    let workload_pid = spawn_workload(&process)?;
    {
        let mut s = status.lock().expect("status poisoned");
        s.state = WorkloadState::Running;
    }

    reap_until_workload_exits(workload_pid, &status);

    // Keep PID 1 alive so the vsock agent can continue reporting the exit
    // status; the host stops the microVM when it observes `exited`.
    loop {
        std::thread::park();
    }
}

/// Launch the container workload as a child process with the resolved
/// environment, working directory, and credentials. Returns its pid.
fn spawn_workload(process: &ResolvedProcess) -> Result<Pid, Box<dyn std::error::Error>> {
    let (program, args) = process.argv.split_first().ok_or("empty argv")?;

    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(&process.cwd)
        .env_clear()
        .envs(process.env.iter().filter_map(|kv: &String| kv.split_once('=')));

    let uid = process.uid;
    let gid = process.gid;
    // Drop supplementary groups to just the primary gid before the runtime
    // applies uid/gid. Runs in the child, still privileged, pre-exec.
    unsafe {
        cmd.pre_exec(move || setgroups(&[Gid::from_raw(gid)]).map_err(std::io::Error::from));
    }
    cmd.gid(gid).uid(uid);

    let child = cmd
        .spawn()
        .map_err(|e| format!("exec workload {program}: {e}"))?;
    Ok(Pid::from_raw(child.id() as i32))
}

/// Reap children until the workload process is reaped, recording its exit code.
/// Continues reaping any other reparented zombies encountered along the way.
fn reap_until_workload_exits(workload: Pid, status: &SharedStatus) {
    loop {
        match waitpid(Pid::from_raw(-1), None) {
            Ok(WaitStatus::Exited(pid, code)) => {
                if pid == workload {
                    record_exit(status, code);
                    return;
                }
            }
            Ok(WaitStatus::Signaled(pid, sig, _)) => {
                if pid == workload {
                    // Shell convention: a process killed by signal N exits 128+N.
                    record_exit(status, 128 + sig as i32);
                    return;
                }
            }
            Ok(_) => {} // stopped/continued/etc — keep waiting
            Err(nix::errno::Errno::ECHILD) => {
                // No children left but the workload was never seen exiting;
                // treat as an unknown exit so the host is not left hanging.
                record_exit(status, -1);
                return;
            }
            Err(nix::errno::Errno::EINTR) => continue,
            Err(e) => {
                eprintln!("[sandbox-init] waitpid failed: {e}");
                record_exit(status, -1);
                return;
            }
        }
    }
}

fn record_exit(status: &SharedStatus, code: i32) {
    let mut s = status.lock().expect("status poisoned");
    s.state = WorkloadState::Exited;
    s.exit_code = Some(code);
    eprintln!("[sandbox-init] workload exited with code {code}");
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
