//! Child reaping and exit-code routing (Linux only).
//!
//! As PID 1, the init is the parent of the workload, of every exec-session
//! child (issue #423), and — by reparenting — of any orphan in the guest.
//! A single forever-running `waitpid(-1)` loop reaps them all and routes each
//! exit code to whoever cares:
//!
//! * the **workload** pid updates [`SharedStatus`] exactly as v1 did
//!   (signal N reported as `128 + N`; an unexpected `ECHILD` before the
//!   workload's exit was observed records the `-1` fallback so the host is
//!   never left hanging);
//! * **registered** pids (exec children) have their code sent to the waiting
//!   session through the [`ChildRegistry`];
//! * **unknown** pids are remembered in a bounded unclaimed map so a
//!   register-after-exit race still resolves;
//! * on `ECHILD` the reaper parks on a condvar until a new child is spawned,
//!   instead of exiting — exec sessions can start at any point in the
//!   microVM's life.

use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};

use nix::errno::Errno;
use nix::sys::wait::{waitpid, WaitStatus};
use nix::unistd::Pid;

use strato_sandbox_init::protocol::WorkloadState;

use super::vsock::SharedStatus;

/// Upper bound on remembered exits nobody has (yet) registered for. 64 keeps
/// the register-after-exit race window covered without unbounded growth if
/// reparented orphans nobody waits on keep arriving.
const MAX_UNCLAIMED: usize = 64;

/// The workload's pid, shared between the reaper (reader) and whoever spawns
/// the workload. `None` until a workload has been launched — which, since
/// warm start (issue #426), can happen long after the reaper started: a
/// `warm_hold` guest parks with no workload and a `launch` control request
/// spawns it from a vsock connection thread.
pub type SharedWorkloadPid = Arc<Mutex<Option<Pid>>>;

/// Routing table between the reaper and exec sessions.
pub struct ChildRegistry {
    inner: Mutex<RegistryInner>,
    /// Notified on every spawn/registration so a reaper parked on `ECHILD`
    /// wakes up and calls `waitpid` again.
    activity: Condvar,
}

struct RegistryInner {
    /// Exec sessions waiting for a pid's exit code.
    waiters: HashMap<i32, Sender<i32>>,
    /// Exit codes reaped before anyone registered for them, oldest first,
    /// bounded to [`MAX_UNCLAIMED`].
    unclaimed: VecDeque<(i32, i32)>,
    /// Bumped whenever a child is spawned or registered; the reaper compares
    /// generations to avoid missing a spawn that raced its `ECHILD`.
    spawn_generation: u64,
}

impl ChildRegistry {
    pub fn new() -> Self {
        ChildRegistry {
            inner: Mutex::new(RegistryInner {
                waiters: HashMap::new(),
                unclaimed: VecDeque::new(),
                spawn_generation: 0,
            }),
            activity: Condvar::new(),
        }
    }

    /// Register interest in `pid`'s exit code; call immediately after
    /// spawning it. If the reaper already collected the exit (the
    /// reap-before-register race) the code is delivered instantly. Also
    /// wakes a reaper parked on `ECHILD`.
    pub fn register(&self, pid: i32) -> Receiver<i32> {
        let (tx, rx) = channel();
        let mut inner = self.inner.lock().expect("child registry poisoned");
        if let Some(pos) = inner.unclaimed.iter().position(|&(p, _)| p == pid) {
            if let Some((_, code)) = inner.unclaimed.remove(pos) {
                let _ = tx.send(code);
            }
        } else {
            inner.waiters.insert(pid, tx);
        }
        inner.spawn_generation += 1;
        self.activity.notify_all();
        rx
    }

    /// Wake the reaper after spawning a child that is not `register`ed for
    /// exit-code delivery (the workload — its exit goes to [`SharedStatus`]).
    pub fn notify_spawned(&self) {
        let mut inner = self.inner.lock().expect("child registry poisoned");
        inner.spawn_generation += 1;
        self.activity.notify_all();
    }

    /// Take `pid`'s exit code out of the unclaimed map, if the reaper already
    /// collected it. Used by the workload launch path: the reaper only learns
    /// the workload's pid after the spawn returns, so an exit reaped in that
    /// window lands in the unclaimed map as an unknown pid and is claimed
    /// back here.
    pub fn claim_unclaimed(&self, pid: i32) -> Option<i32> {
        let mut inner = self.inner.lock().expect("child registry poisoned");
        inner
            .unclaimed
            .iter()
            .position(|&(p, _)| p == pid)
            .and_then(|pos| inner.unclaimed.remove(pos))
            .map(|(_, code)| code)
    }

    /// Drop every remembered unclaimed exit. Called right before the
    /// workload spawns: anything reaped earlier belongs to reparented
    /// orphans nobody will ever wait on, and leaving those entries around
    /// would let a recycled pid mis-claim a stale exit as the workload's
    /// (exec sessions cannot race this — they only start after boot
    /// completes, which is after the workload launch).
    pub fn clear_unclaimed(&self) {
        let mut inner = self.inner.lock().expect("child registry poisoned");
        inner.unclaimed.clear();
    }

    fn spawn_generation(&self) -> u64 {
        self.inner
            .lock()
            .expect("child registry poisoned")
            .spawn_generation
    }

    /// Deliver a reaped exit code to its waiter, or park it as unclaimed.
    fn record_exit(&self, pid: i32, code: i32) {
        let mut inner = self.inner.lock().expect("child registry poisoned");
        if let Some(tx) = inner.waiters.remove(&pid) {
            // A vanished session (receiver dropped) is fine; ignore the error.
            let _ = tx.send(code);
        } else {
            if inner.unclaimed.len() >= MAX_UNCLAIMED {
                inner.unclaimed.pop_front();
            }
            inner.unclaimed.push_back((pid, code));
        }
    }

    /// Block until the spawn generation moves past `seen`, i.e. until there
    /// is a new child to wait on.
    fn wait_for_spawn(&self, seen: u64) {
        let mut inner = self.inner.lock().expect("child registry poisoned");
        while inner.spawn_generation == seen {
            inner = self.activity.wait(inner).expect("child registry poisoned");
        }
    }
}

impl Default for ChildRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// PID 1's forever duty: reap every child and route exit codes. Never
/// returns — after the workload has exited it keeps reaping exec children
/// and orphans until the host tears the microVM down.
///
/// The workload pid is read from a shared slot rather than taken as a
/// parameter: a `warm_hold` guest (issue #426) enters this loop with no
/// workload at all, and the `launch` control request fills the slot later
/// from a vsock thread. Whether the workload exit has been recorded is
/// likewise derived from [`SharedStatus`] (`state == Exited`) so the launch
/// path's [`ChildRegistry::claim_unclaimed`] recording composes with the
/// fallbacks here.
pub fn reap_forever(
    workload: &SharedWorkloadPid,
    status: &SharedStatus,
    registry: &ChildRegistry,
) -> ! {
    loop {
        // Sample before waitpid: a spawn racing an ECHILD result bumps the
        // generation past this value, so wait_for_spawn returns immediately
        // instead of parking with a live child outstanding.
        let generation = registry.spawn_generation();
        match waitpid(Pid::from_raw(-1), None) {
            Ok(WaitStatus::Exited(pid, code)) => {
                deliver_exit(pid, code, workload, status, registry);
            }
            Ok(WaitStatus::Signaled(pid, sig, _)) => {
                // Shell convention: a process killed by signal N exits 128+N.
                deliver_exit(pid, 128 + sig as i32, workload, status, registry);
            }
            Ok(_) => {} // stopped/continued/etc — keep waiting
            Err(Errno::ECHILD) => {
                // No children left. If a workload was spawned but its exit
                // was never observed, record it — preferring an exit the
                // reaper collected as an unknown pid in the window before
                // the launch path published the workload pid, and falling
                // back to -1 so the host is never left hanging. A held
                // guest (no workload yet) simply parks until something
                // spawns.
                record_fallback_workload_exit(workload, status, registry);
                registry.wait_for_spawn(generation);
            }
            Err(Errno::EINTR) => {}
            Err(e) => {
                eprintln!("[sandbox-init] waitpid failed: {e}");
                record_fallback_workload_exit(workload, status, registry);
                // Park rather than spinning on a persistent error.
                registry.wait_for_spawn(generation);
            }
        }
    }
}

fn workload_pid(workload: &SharedWorkloadPid) -> Option<Pid> {
    *workload.lock().expect("workload pid poisoned")
}

fn workload_exit_recorded(status: &SharedStatus) -> bool {
    status.lock().expect("status poisoned").state == WorkloadState::Exited
}

fn deliver_exit(
    pid: Pid,
    code: i32,
    workload: &SharedWorkloadPid,
    status: &SharedStatus,
    registry: &ChildRegistry,
) {
    if workload_pid(workload) == Some(pid) && record_workload_exit_once(status, code) {
        return;
    }
    // Not the workload — or the workload's exit was already recorded, in
    // which case this pid is a recycled one now belonging to some other
    // child (an exec session) and its code must still reach its waiter.
    registry.record_exit(pid.as_raw(), code);
}

/// The reaper ran out of children while a workload was supposedly alive:
/// its exit was either reaped as an unknown pid before the launch path
/// published the workload pid (claim it back), or genuinely lost (-1).
fn record_fallback_workload_exit(
    workload: &SharedWorkloadPid,
    status: &SharedStatus,
    registry: &ChildRegistry,
) {
    let Some(pid) = workload_pid(workload) else {
        return;
    };
    if workload_exit_recorded(status) {
        return;
    }
    let code = registry.claim_unclaimed(pid.as_raw()).unwrap_or(-1);
    record_workload_exit_once(status, code);
}

/// Record the workload's exit unless one was already recorded (the status
/// being `Exited` is the single source of truth, shared with the launch
/// path's claim_unclaimed recording). Returns whether this call recorded it.
pub(crate) fn record_workload_exit_once(status: &SharedStatus, code: i32) -> bool {
    let mut s = status.lock().expect("status poisoned");
    if s.state == WorkloadState::Exited {
        return false;
    }
    s.state = WorkloadState::Exited;
    s.exit_code = Some(code);
    eprintln!("[sandbox-init] workload exited with code {code}");
    true
}
