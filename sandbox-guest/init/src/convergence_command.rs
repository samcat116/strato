//! Bounded command execution for guest desired-state observation and apply.
//!
//! Package managers can block on mirrors or leave pipe-owning descendants.
//! Poll nonblocking pipes under one deadline instead of waiting on reader
//! threads, and terminate the entire command group on every exit path.

use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum CommandFailure {
    InvalidBudget,
    Io(String),
    TimedOut,
    OutputLimit,
    Exit(Option<i32>),
}

#[derive(Debug, PartialEq, Eq)]
pub struct CommandOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

struct RunningCommand(Child);

impl Drop for RunningCommand {
    fn drop(&mut self) {
        // SAFETY: process_group(0) established a separate group with this pid.
        // Descendants must not outlive the budget or retain our output pipes.
        unsafe { libc::kill(-(self.0.id() as i32), libc::SIGKILL) };
        let _ = self.0.wait();
    }
}

fn nonblocking(fd: i32) -> io::Result<()> {
    // SAFETY: the live child pipe owns fd throughout both fcntl calls.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn drain(
    reader: &mut impl Read,
    bytes: &mut Vec<u8>,
    remaining: &mut usize,
) -> Result<bool, CommandFailure> {
    let mut buffer = [0; 4096];
    // Bound each pass too: a continuously writing process must not prevent
    // checking the deadline or draining its other pipe.
    for _ in 0..8 {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                if count > *remaining {
                    return Err(CommandFailure::OutputLimit);
                }
                *remaining -= count;
                bytes.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(CommandFailure::Io(error.to_string())),
        }
    }
    Ok(false)
}

/// Execute an argument-array command with a shared stdout/stderr byte ceiling.
/// No shell is introduced. The caller supplies the remaining convergence
/// budget, so several commands cannot each consume a fresh full budget.
pub fn run(
    command: &mut Command,
    budget: Duration,
    max_output_bytes: usize,
) -> Result<CommandOutput, CommandFailure> {
    let deadline = Instant::now()
        .checked_add(budget)
        .filter(|_| !budget.is_zero())
        .ok_or(CommandFailure::InvalidBudget)?;
    let mut child = RunningCommand(
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .map_err(|error| CommandFailure::Io(error.to_string()))?,
    );
    let mut stdout = child.0.stdout.take().expect("piped stdout");
    let mut stderr = child.0.stderr.take().expect("piped stderr");
    nonblocking(stdout.as_raw_fd())
        .and_then(|_| nonblocking(stderr.as_raw_fd()))
        .map_err(|error| CommandFailure::Io(error.to_string()))?;
    let mut output = CommandOutput {
        stdout: Vec::new(),
        stderr: Vec::new(),
    };
    let mut remaining = max_output_bytes;
    loop {
        if Instant::now() >= deadline {
            return Err(CommandFailure::TimedOut);
        }
        let stdout_done = drain(&mut stdout, &mut output.stdout, &mut remaining)?;
        let stderr_done = drain(&mut stderr, &mut output.stderr, &mut remaining)?;
        let status = child
            .0
            .try_wait()
            .map_err(|error| CommandFailure::Io(error.to_string()))?;
        if let Some(status) = status {
            if !status.success() {
                return Err(CommandFailure::Exit(status.code()));
            }
            if stdout_done && stderr_done {
                return Ok(output);
            }
        }
        std::thread::sleep(
            Duration::from_millis(5).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", script]);
        command
    }

    #[test]
    fn captures_both_pipes_and_surfaces_exit_failure() {
        let output = run(
            &mut shell("printf observed; printf diagnostic >&2"),
            Duration::from_secs(2),
            100,
        )
        .unwrap();
        assert_eq!(output.stdout, b"observed");
        assert_eq!(output.stderr, b"diagnostic");
        assert_eq!(
            run(&mut shell("exit 7"), Duration::from_secs(2), 100),
            Err(CommandFailure::Exit(Some(7)))
        );
    }

    #[test]
    fn bounds_hung_commands_and_descendant_owned_pipes() {
        for script in ["sleep 30", "sleep 30 & exit 0"] {
            let started = Instant::now();
            assert_eq!(
                run(&mut shell(script), Duration::from_millis(100), 100),
                Err(CommandFailure::TimedOut)
            );
            assert!(started.elapsed() < Duration::from_secs(2));
        }
    }

    #[test]
    fn output_ceiling_is_shared_and_floods_do_not_deadlock() {
        assert_eq!(
            run(
                &mut shell("printf 12345; printf 67890 >&2"),
                Duration::from_secs(2),
                9
            ),
            Err(CommandFailure::OutputLimit)
        );
        assert!(run(
            &mut shell("printf 12345; printf 67890 >&2"),
            Duration::from_secs(2),
            10
        )
        .is_ok());
        assert_eq!(
            run(&mut shell("yes"), Duration::from_secs(2), 8192),
            Err(CommandFailure::OutputLimit)
        );
    }

    #[test]
    fn rejects_zero_budget_before_execution() {
        assert_eq!(
            run(&mut shell("exit 0"), Duration::ZERO, 100),
            Err(CommandFailure::InvalidBudget)
        );
    }
}
