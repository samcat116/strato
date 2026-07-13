//! `strato-sandbox-init` — PID 1 inside a Strato sandbox microVM (issue #419).
//!
//! On Linux this is the real init: it brings up the guest, launches the
//! container workload, reaps zombies, and serves the vsock control agent. On
//! any other host it is a stub — the portable logic it drives is exercised by
//! the library's unit tests (`strato_sandbox_init::{config, protocol}`).

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    linux::run()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("strato-sandbox-init is a Linux-only guest init; nothing to do on this host");
    std::process::exit(1);
}
