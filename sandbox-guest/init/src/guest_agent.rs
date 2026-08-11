//! Strato control agent for general-purpose Linux VMs (STR-77).
//!
//! This is a normal service process, not PID 1. It binds only AF_VSOCK,
//! answers the shared guest control protocol, and runs host-requested commands
//! in the already-booted VM. Packaging and the systemd unit belong to STR-80.

#[cfg(target_os = "linux")]
#[path = "guest_agent/mod.rs"]
mod guest_agent;

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    guest_agent::run()
}

#[cfg(not(target_os = "linux"))]
fn main() -> std::process::ExitCode {
    eprintln!("strato-guest-agent is supported only on Linux");
    std::process::ExitCode::FAILURE
}
