//! Opt-in v5 idle accounting. Default/published binaries remain protocol v4.
//! The monitor is outside the workload cgroup; all eligible workload processes
//! are non-root, contained, socket-free and have no NIC. Missing coverage denies.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::time::Instant;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Activity {
    pub sandbox_id: String,
    pub nonce: String,
    pub probe_id: String,
    pub monitor_incarnation: String,
    pub sample_sequence: u64,
    pub activity_epoch: u64,
    pub quiet_for_milliseconds: Option<u64>,
    pub coverage: String,
    pub trusted: bool,
    pub active_exec_session_ids: Option<Vec<String>>,
    pub anonymous_exec_count: Option<u32>,
    pub pending_exec_count: Option<u32>,
    pub workload_cpu_microseconds: Option<u64>,
    pub workload_read_bytes: Option<u64>,
    pub workload_write_bytes: Option<u64>,
    pub external_socket_count: Option<u32>,
    pub nic_count: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Counters {
    pub cpu: u64,
    pub read: u64,
    pub written: u64,
    pub sockets: u32,
}
pub trait Backend: Send {
    fn counters(&self) -> Result<Counters, String>;
    fn freeze(&mut self, frozen: bool) -> Result<(), String>;
}

pub struct Monitor {
    backend: Option<Box<dyn Backend>>,
    pub incarnation: String,
    sequence: u64,
    epoch: u64,
    last_activity: Instant,
    baseline: Option<Counters>,
    sessions: BTreeMap<u64, Option<String>>,
    next_session: u64,
    prepared: Option<(String, String)>,
    released: BTreeMap<String, String>,
    exhausted: bool,
}
impl Monitor {
    pub fn new(incarnation: String, backend: Option<Box<dyn Backend>>) -> Self {
        Self {
            backend,
            incarnation,
            sequence: 0,
            epoch: 0,
            last_activity: Instant::now(),
            baseline: None,
            sessions: BTreeMap::new(),
            next_session: 0,
            prepared: None,
            released: BTreeMap::new(),
            exhausted: false,
        }
    }
    pub fn supported(&self) -> bool {
        self.backend.is_some()
    }
    pub fn touch(&mut self) {
        self.last_activity = Instant::now();
        match self.epoch.checked_add(1).filter(|n| *n <= i64::MAX as u64) {
            Some(n) => self.epoch = n,
            None => self.exhausted = true,
        }
    }
    pub fn begin_exec(&mut self, id: Option<String>) -> Result<u64, String> {
        if self.prepared.is_some() {
            return Err("idle preparation owns guest admission".into());
        }
        let n = self
            .next_session
            .checked_add(1)
            .ok_or("exec ledger exhausted")?;
        if self.sessions.len() >= 4096 {
            return Err("exec ledger full".into());
        }
        if let Some(ref id) = id {
            if !valid_id(id) {
                return Err("invalid session identity".into());
            }
        }
        if let Some(ref id) = id {
            if self.sessions.values().any(|old| {
                old.as_ref()
                    .map(|v| v.eq_ignore_ascii_case(id))
                    .unwrap_or(false)
            }) {
                return Err("exec identity is already active".into());
            }
        }
        self.next_session = n;
        self.sessions.insert(n, id.map(|v| v.to_ascii_lowercase()));
        self.touch();
        Ok(n)
    }
    pub fn end_exec(&mut self, id: u64) {
        if self.sessions.remove(&id).is_some() {
            self.touch();
        }
    }
    pub fn activity(
        &mut self,
        sandbox: &str,
        nonce: &str,
        probe: &str,
        trusted: bool,
        no_nic: bool,
    ) -> Activity {
        self.sequence = match self
            .sequence
            .checked_add(1)
            .filter(|n| *n <= i64::MAX as u64)
        {
            Some(n) => n,
            None => {
                self.exhausted = true;
                i64::MAX as u64
            }
        };
        let counters = self.backend.as_ref().and_then(|b| b.counters().ok());
        let complete = trusted && no_nic && !self.exhausted && counters.is_some();
        if !complete || counters != self.baseline {
            self.touch();
        }
        self.baseline = counters;
        let anonymous = self.sessions.values().filter(|id| id.is_none()).count() as u32;
        Activity {
            sandbox_id: sandbox.into(),
            nonce: nonce.into(),
            probe_id: probe.into(),
            monitor_incarnation: self.incarnation.clone(),
            sample_sequence: self.sequence,
            activity_epoch: self.epoch,
            quiet_for_milliseconds: complete
                .then(|| self.last_activity.elapsed().as_millis().min(86_400_000) as u64),
            coverage: if complete { "complete" } else { "unknown" }.into(),
            trusted: complete,
            active_exec_session_ids: complete
                .then(|| self.sessions.values().filter_map(Clone::clone).collect()),
            anonymous_exec_count: complete.then_some(anonymous),
            pending_exec_count: complete.then_some(0),
            workload_cpu_microseconds: counters.map(|c| c.cpu),
            workload_read_bytes: counters.map(|c| c.read),
            workload_write_bytes: counters.map(|c| c.written),
            external_socket_count: counters.map(|c| c.sockets),
            nic_count: no_nic.then_some(0),
        }
    }
    pub fn prepare(
        &mut self,
        op: &str,
        token: &str,
        epoch: u64,
        quiet_ms: u64,
        sandbox: &str,
        nonce: &str,
        trusted: bool,
        no_nic: bool,
    ) -> Result<(), String> {
        if !valid_id(op) || !valid_id(token) || quiet_ms == 0 || quiet_ms > 86_400_000 {
            return Err("invalid idle claim".into());
        }
        if let Some(ref old) = self.prepared {
            return if same(old, op, token) {
                Ok(())
            } else {
                Err("another idle operation owns admission".into())
            };
        }
        if self.released.get(&op.to_ascii_lowercase()).is_some() {
            return Err("released idle operation cannot be replayed".into());
        }
        if self.released.len() >= 4096 {
            return Err("idle operation history full".into());
        }
        let sample = self.activity(sandbox, nonce, op, trusted, no_nic);
        if sample.coverage != "complete"
            || !self.sessions.is_empty()
            || sample.external_socket_count != Some(0)
            || sample.activity_epoch != epoch
            || sample.quiet_for_milliseconds.unwrap_or(0) < quiet_ms
        {
            return Err("activity is busy or unknown".into());
        }
        // Mutex owner closes every exec admission before touching the freezer.
        self.prepared = Some((op.to_ascii_lowercase(), token.to_ascii_lowercase()));
        let before = self.baseline;
        let result = self
            .backend
            .as_mut()
            .ok_or("unsupported idle monitor")?
            .freeze(true);
        let after = self.backend.as_ref().and_then(|b| b.counters().ok());
        if result.is_err() || after != before || after.is_none() {
            // Keep admission closed when thaw cannot be proved; query/release
            // remains available for the journal owner's recovery.
            self.touch();
            self.release(op, token)?;
            return Err("activity raced the guest freeze".into());
        }
        Ok(())
    }
    pub fn query(&self, op: &str, token: &str) -> Result<&'static str, String> {
        if let Some(ref current) = self.prepared {
            return if same(current, op, token) {
                Ok("prepared")
            } else {
                Err("idle token mismatch".into())
            };
        }
        if let Some(old) = self.released.get(&op.to_ascii_lowercase()) {
            return if old.eq_ignore_ascii_case(token) {
                Ok("released")
            } else {
                Err("idle token mismatch".into())
            };
        }
        Ok("absent")
    }
    pub fn release(&mut self, op: &str, token: &str) -> Result<(), String> {
        if let Some(ref current) = self.prepared {
            if !same(current, op, token) {
                return Err("idle token mismatch".into());
            }
            self.backend
                .as_mut()
                .ok_or("unsupported idle monitor")?
                .freeze(false)?;
            let (operation, token) = self.prepared.take().unwrap();
            self.released.insert(operation, token);
            self.baseline = None;
            self.touch();
            return Ok(());
        }
        if !valid_id(op) || !valid_id(token) {
            return Err("invalid idle identity".into());
        }
        if let Some(old) = self.released.get(&op.to_ascii_lowercase()) {
            return if old.eq_ignore_ascii_case(token) {
                Ok(())
            } else {
                Err("idle token mismatch".into())
            };
        }
        if self.released.len() >= 4096 {
            return Err("idle operation history full".into());
        }
        // A release that beats an undelivered prepare cancels that operation
        // permanently. It never thaws another operation's workload.
        self.released
            .insert(op.to_ascii_lowercase(), token.to_ascii_lowercase());
        Ok(())
    }
}
fn same(pair: &(String, String), op: &str, token: &str) -> bool {
    pair.0.eq_ignore_ascii_case(op) && pair.1.eq_ignore_ascii_case(token)
}
pub fn valid_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

#[cfg(all(target_os = "linux", feature = "idle-policy-v5"))]
pub mod linux {
    use super::{Backend, Counters};
    use std::{
        fs,
        os::unix::fs::MetadataExt,
        path::{Path, PathBuf},
    };
    pub const ROOT: &str = "/sys/fs/cgroup/strato-idle-workload";
    pub struct Cgroup {
        root: PathBuf,
        inode: u64,
    }
    impl Cgroup {
        pub fn open() -> Result<Self, String> {
            fs::create_dir_all("/sys/fs/cgroup").map_err(|e| e.to_string())?;
            if !Path::new("/sys/fs/cgroup/cgroup.controllers").exists() {
                let path = std::ffi::CString::new("/sys/fs/cgroup").unwrap();
                let kind = b"cgroup2\0";
                let rc = unsafe {
                    libc::mount(
                        kind.as_ptr().cast(),
                        path.as_ptr(),
                        kind.as_ptr().cast(),
                        0,
                        std::ptr::null(),
                    )
                };
                if rc != 0 {
                    return Err(std::io::Error::last_os_error().to_string());
                }
            }
            fs::write("/sys/fs/cgroup/cgroup.subtree_control", "+cpu +io")
                .map_err(|e| e.to_string())?;
            fs::create_dir_all(ROOT).map_err(|e| e.to_string())?;
            let root = PathBuf::from(ROOT);
            for file in ["cpu.stat", "io.stat", "cgroup.freeze", "cgroup.events"] {
                if !root.join(file).exists() {
                    return Err("idle controller unavailable".into());
                }
            }
            if !fs::read_to_string(root.join("cgroup.procs"))
                .map_err(|e| e.to_string())?
                .trim()
                .is_empty()
            {
                // A new daemon cannot reconstruct another monitor's exec ledger.
                return Err("existing workload admission ownership is unknown".into());
            }
            let inode = fs::metadata(&root).map_err(|e| e.to_string())?.ino();
            Ok(Self { root, inode })
        }
        fn read(&self, name: &str) -> Result<String, String> {
            if fs::metadata(&self.root).map_err(|e| e.to_string())?.ino() != self.inode {
                return Err("idle cgroup replaced".into());
            }
            use std::io::Read;
            let mut value = String::new();
            fs::File::open(self.root.join(name))
                .map_err(|e| e.to_string())?
                .take((1 << 20) + 1)
                .read_to_string(&mut value)
                .map_err(|e| e.to_string())?;
            if value.len() > 1 << 20 {
                return Err("idle accounting oversized".into());
            }
            Ok(value)
        }
    }
    impl Backend for Cgroup {
        fn counters(&self) -> Result<Counters, String> {
            let cpu = self
                .read("cpu.stat")?
                .lines()
                .find_map(|l| l.strip_prefix("usage_usec ").and_then(|n| n.parse().ok()))
                .ok_or("CPU coverage missing")?;
            let mut read = 0u64;
            let mut written = 0u64;
            for line in self.read("io.stat")?.lines() {
                for item in line.split_whitespace().skip(1) {
                    if let Some(n) = item.strip_prefix("rbytes=") {
                        read = read
                            .checked_add(n.parse().map_err(|_| "bad I/O counter")?)
                            .ok_or("I/O overflow")?;
                    }
                    if let Some(n) = item.strip_prefix("wbytes=") {
                        written = written
                            .checked_add(n.parse().map_err(|_| "bad I/O counter")?)
                            .ok_or("I/O overflow")?;
                    }
                }
            }
            if fs::read_dir("/sys/class/net")
                .map_err(|e| e.to_string())?
                .any(|e| e.map(|e| e.file_name() != "lo").unwrap_or(true))
            {
                return Err("network coverage unsupported".into());
            }
            let memory = fs::read_to_string("/proc/meminfo").map_err(|e| e.to_string())?;
            for field in ["Dirty:", "Writeback:"] {
                let pending = memory
                    .lines()
                    .find(|line| line.starts_with(field))
                    .and_then(|line| line.split_whitespace().nth(1))
                    .and_then(|value| value.parse::<u64>().ok())
                    .ok_or("pending I/O coverage missing")?;
                if pending != 0 {
                    return Err("pending workload writeback".into());
                }
            }
            let mut sockets = 0u32;
            let mut tasks = 0usize;
            let mut descriptors = 0usize;
            for entry in fs::read_dir("/proc").map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.parse::<u32>().is_err() || name == "1" {
                    continue;
                }
                tasks += 1;
                if tasks > 4096 {
                    return Err("task coverage oversized".into());
                }
                let stat =
                    fs::read_to_string(entry.path().join("stat")).map_err(|e| e.to_string())?;
                let tail = stat
                    .rsplit_once(')')
                    .ok_or("bad proc stat")?
                    .1
                    .split_whitespace()
                    .collect::<Vec<_>>();
                let flags: u64 = tail
                    .get(6)
                    .ok_or("bad proc flags")?
                    .parse()
                    .map_err(|_| "bad proc flags")?;
                if flags & 0x0020_0000 != 0 {
                    continue;
                } // PF_KTHREAD
                if tail.first() == Some(&"D") || tail.first() == Some(&"R") {
                    return Err("workload is runnable or blocked".into());
                }
                let group =
                    fs::read_to_string(entry.path().join("cgroup")).map_err(|e| e.to_string())?;
                if !group.lines().any(|l| {
                    l == "0::/strato-idle-workload" || l.starts_with("0::/strato-idle-workload/")
                }) {
                    return Err("unaccounted task".into());
                }
                let status =
                    fs::read_to_string(entry.path().join("status")).map_err(|e| e.to_string())?;
                let uid = status
                    .lines()
                    .find(|l| l.starts_with("Uid:"))
                    .filter(|l| l.split_whitespace().skip(1).all(|uid| uid != "0"))
                    .and_then(|l| l.split_whitespace().nth(1))
                    .ok_or("UID coverage missing")?;
                if uid == "0" {
                    return Err("privileged workload monitoring is untrusted".into());
                }
                for fd in fs::read_dir(entry.path().join("fd")).map_err(|e| e.to_string())? {
                    descriptors += 1;
                    if descriptors > 65536 {
                        return Err("descriptor coverage oversized".into());
                    }
                    let target = fs::read_link(fd.map_err(|e| e.to_string())?.path())
                        .map_err(|e| e.to_string())?;
                    if target.to_string_lossy().starts_with("socket:[") {
                        sockets = sockets.checked_add(1).ok_or("socket counter overflow")?;
                    }
                }
            }
            let after: u64 = self
                .read("cpu.stat")?
                .lines()
                .find_map(|l| l.strip_prefix("usage_usec ").and_then(|n| n.parse().ok()))
                .ok_or("CPU coverage missing")?;
            if after != cpu {
                return Err("activity changed during measurement".into());
            }
            Ok(Counters {
                cpu,
                read,
                written,
                sockets,
            })
        }
        fn freeze(&mut self, frozen: bool) -> Result<(), String> {
            fs::write(
                self.root.join("cgroup.freeze"),
                if frozen { "1" } else { "0" },
            )
            .map_err(|e| e.to_string())?;
            let began = std::time::Instant::now();
            loop {
                let expected = if frozen { "frozen 1" } else { "frozen 0" };
                if self.read("cgroup.events")?.lines().any(|l| l == expected) {
                    return Ok(());
                }
                if began.elapsed().as_secs() >= 2 {
                    return Err("freezer acknowledgement timed out".into());
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
    }
    /// Called in the child before exec/credential drop, using no heap allocation.
    pub fn join_current_child() -> std::io::Result<()> {
        let path = b"/sys/fs/cgroup/strato-idle-workload/cgroup.procs\0";
        let fd = unsafe { libc::open(path.as_ptr().cast(), libc::O_WRONLY | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let result = unsafe { libc::write(fd, b"0\n".as_ptr().cast(), 2) };
        let error = std::io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        if result == 2 {
            Ok(())
        } else {
            Err(error)
        }
    }
}

/// Only an explicitly built, working monitor advertises v5. Default artifacts
/// and hosts without cgroup controllers retain the published v4 surface.
pub fn from_system() -> Monitor {
    let incarnation = std::fs::read_to_string("/proc/sys/kernel/random/uuid")
        .unwrap_or_default()
        .trim()
        .to_owned();
    #[cfg(all(target_os = "linux", feature = "idle-policy-v5"))]
    let backend = if valid_id(&incarnation) {
        linux::Cgroup::open()
            .ok()
            .map(|b| Box::new(b) as Box<dyn Backend>)
    } else {
        None
    };
    #[cfg(not(all(target_os = "linux", feature = "idle-policy-v5")))]
    let backend = None;
    Monitor::new(incarnation, backend)
}
pub fn join_child(enabled: bool) -> std::io::Result<()> {
    #[cfg(all(target_os = "linux", feature = "idle-policy-v5"))]
    if enabled {
        // Opt-in non-root workloads cannot regain privilege through setuid
        // executables or file capabilities and replace the monitor.
        if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        return linux::join_current_child();
    }
    let _ = enabled;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    const OP: &str = "00000000-0000-0000-0000-000000000001";
    const TOKEN: &str = "00000000-0000-0000-0000-000000000002";
    #[derive(Default)]
    struct State {
        frozen: bool,
        fail_thaw: bool,
        race: bool,
    }
    struct Fake(Arc<Mutex<State>>);
    impl Backend for Fake {
        fn counters(&self) -> Result<Counters, String> {
            let s = self.0.lock().unwrap();
            Ok(Counters {
                cpu: if s.race && s.frozen { 1 } else { 0 },
                read: 0,
                written: 0,
                sockets: 0,
            })
        }
        fn freeze(&mut self, frozen: bool) -> Result<(), String> {
            let mut s = self.0.lock().unwrap();
            if !frozen && s.fail_thaw {
                return Err("thaw unavailable".into());
            }
            s.frozen = frozen;
            Ok(())
        }
    }
    fn ready() -> (Monitor, Arc<Mutex<State>>, u64) {
        let backend = Arc::new(Mutex::new(State::default()));
        let mut monitor = Monitor::new(OP.into(), Some(Box::new(Fake(backend.clone()))));
        let epoch = monitor
            .activity("sandbox", "nonce", OP, true, true)
            .activity_epoch;
        monitor.last_activity = Instant::now() - std::time::Duration::from_secs(600);
        (monitor, backend, epoch)
    }
    #[test]
    fn missing_monitor_and_network_never_claim_quiet() {
        let mut unknown = Monitor::new(OP.into(), None);
        assert_eq!(
            unknown.activity("s", "n", OP, true, true).coverage,
            "unknown"
        );
        let (mut m, _, _) = ready();
        assert_eq!(m.activity("s", "n", OP, true, false).coverage, "unknown");
        assert!(m
            .prepare(OP, TOKEN, m.epoch, 1, "s", "n", true, false)
            .is_err());
    }
    #[test]
    fn prepare_replay_release_and_closed_admission() {
        let (mut m, state, epoch) = ready();
        m.prepare(OP, TOKEN, epoch, 300000, "s", "n", true, true)
            .unwrap();
        assert!(state.lock().unwrap().frozen);
        assert!(m.begin_exec(None).is_err());
        // Lost reply retry is idempotent even when the sampled epoch is old.
        m.prepare(OP, TOKEN, 0, 300000, "s", "n", true, true)
            .unwrap();
        assert_eq!(m.query(OP, TOKEN).unwrap(), "prepared");
        assert!(m.release(OP, OP).is_err());
        m.release(OP, TOKEN).unwrap();
        m.release(OP, TOKEN).unwrap();
        assert_eq!(m.query(OP, TOKEN).unwrap(), "released");
        assert!(m
            .prepare(OP, TOKEN, epoch, 300000, "s", "n", true, true)
            .is_err());
        assert!(m.begin_exec(None).is_ok());
    }
    #[test]
    fn active_anonymous_exec_and_epoch_race_deny() {
        let (mut m, _, epoch) = ready();
        let id = m.begin_exec(None).unwrap();
        assert!(m
            .prepare(OP, TOKEN, epoch, 1, "s", "n", true, true)
            .is_err());
        assert_eq!(
            m.activity("s", "n", OP, true, true).anonymous_exec_count,
            Some(1)
        );
        m.end_exec(id);
        let epoch = m.epoch;
        m.end_exec(id);
        assert_eq!(epoch, m.epoch);
        assert!(m
            .prepare(OP, TOKEN, epoch - 1, 1, "s", "n", true, true)
            .is_err());
    }
    #[test]
    fn freeze_race_rolls_back_and_unknown_thaw_keeps_gate_closed() {
        let (mut m, s, epoch) = ready();
        s.lock().unwrap().race = true;
        assert!(m
            .prepare(OP, TOKEN, epoch, 1, "s", "n", true, true)
            .is_err());
        assert!(!s.lock().unwrap().frozen);
        assert_eq!(m.query(OP, TOKEN).unwrap(), "released");
        let (mut m, s, epoch) = ready();
        {
            let mut b = s.lock().unwrap();
            b.race = true;
            b.fail_thaw = true;
        }
        assert!(m
            .prepare(OP, TOKEN, epoch, 1, "s", "n", true, true)
            .is_err());
        assert_eq!(m.query(OP, TOKEN).unwrap(), "prepared");
        assert!(m.begin_exec(None).is_err());
        s.lock().unwrap().fail_thaw = false;
        m.release(OP, TOKEN).unwrap();
    }
    #[test]
    fn release_before_delivery_permanently_cancels_prepare() {
        let (mut m, _, epoch) = ready();
        m.release(OP, TOKEN).unwrap();
        assert_eq!(m.query(OP, TOKEN).unwrap(), "released");
        assert!(m
            .prepare(OP, TOKEN, epoch, 1, "s", "n", true, true)
            .is_err());
        assert!(m.query(OP, OP).is_err());
        assert!(m.release(OP, OP).is_err());
    }
    #[test]
    fn malformed_claims_and_counter_exhaustion_fail_closed() {
        let (mut m, _, epoch) = ready();
        assert!(m
            .prepare("bad", TOKEN, epoch, 1, "s", "n", true, true)
            .is_err());
        m.sequence = i64::MAX as u64;
        assert_eq!(m.activity("s", "n", OP, true, true).coverage, "unknown");
    }
}
