//! STR-90 guest intent and STR-91 level-triggered realization. No file contents
//! or command output are persisted or returned in diagnostics.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GuestConfig {
    pub packages: Vec<Package>,
    pub files: Vec<File>,
    pub services: Vec<Service>,
    pub sysctls: Vec<Sysctl>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Package {
    pub name: String,
    pub state: PackageState,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PackageState {
    Present,
    Absent,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct File {
    pub path: String,
    pub content: String,
    pub mode: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    pub name: String,
    pub enabled: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sysctl {
    pub key: String,
    pub value: String,
}

fn name(value: &str, extra: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || extra.as_bytes().contains(&b))
}
fn unique<'a>(mut values: impl Iterator<Item = &'a str>) -> bool {
    let mut identities = BTreeSet::new();
    values.all(|value| identities.insert(value))
}
impl GuestConfig {
    pub fn validate(&self) -> Result<(), String> {
        let valid = [
            self.packages.len(),
            self.files.len(),
            self.services.len(),
            self.sysctls.len(),
        ]
        .iter()
        .all(|n| *n <= 128)
            && unique(self.packages.iter().map(|e| e.name.as_str()))
            && unique(self.files.iter().map(|e| e.path.as_str()))
            && unique(self.services.iter().map(|e| e.name.as_str()))
            && unique(self.sysctls.iter().map(|e| e.key.as_str()))
            && self.packages.iter().all(|e| name(&e.name, ".+_:-"))
            && self.services.iter().all(|e| name(&e.name, "._-@:"))
            && self.files.iter().all(|e| {
                e.path.starts_with('/')
                    && e.path != "/"
                    && e.path.len() <= 4096
                    && !e.path.chars().any(char::is_control)
                    && e.path
                        .split('/')
                        .skip(1)
                        .all(|p| !p.is_empty() && p != "." && p != "..")
                    && e.mode.len() == 4
                    && e.mode.starts_with('0')
                    && e.mode.bytes().all(|b| (b'0'..=b'7').contains(&b))
                    && e.content.len() <= 65536
                    && !e.content.contains('\0')
            })
            && self.files.iter().map(|e| e.content.len()).sum::<usize>() <= 262144
            && self.sysctls.iter().all(|e| {
                name(&e.key, "._-")
                    && e.key.contains('.')
                    && e.key.split('.').all(|p| !p.is_empty())
                    && !e.value.is_empty()
                    && e.value.len() <= 1024
                    && !e.value.chars().any(|c| c.is_control() && c != '\t')
            });
        if valid {
            Ok(())
        } else {
            Err("invalid guest configuration".into())
        }
    }
}
pub fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PackageObservation {
    pub name: String,
    pub version: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileObservation {
    pub path: String,
    pub sha256: Option<String>,
    pub mode: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceObservation {
    pub name: String,
    pub enabled: Option<bool>,
    pub active_state: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SysctlObservation {
    pub key: String,
    pub value: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Converged,
    Failed,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Section {
    Packages,
    Files,
    Services,
    Sysctls,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ItemFailure {
    pub section: Section,
    pub identity: String,
    pub reason: String,
}
impl ItemFailure {
    fn new(section: Section, identity: &str, reason: String) -> Self {
        Self {
            section,
            identity: identity.into(),
            reason,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Observation {
    pub generation: i64,
    pub status: Status,
    pub error: Option<String>,
    pub failed_item: Option<ItemFailure>,
    pub packages: Vec<PackageObservation>,
    pub files: Vec<FileObservation>,
    pub services: Vec<ServiceObservation>,
    pub sysctls: Vec<SysctlObservation>,
}
impl Observation {
    fn empty(generation: i64) -> Self {
        Self {
            generation,
            status: Status::Converged,
            error: None,
            failed_item: None,
            packages: vec![],
            files: vec![],
            services: vec![],
            sysctls: vec![],
        }
    }
    fn fail(&mut self, error: String) {
        self.failed_item = None;
        self.status = Status::Failed;
        self.error = Some(error);
    }
}

/// All effects pass through this seam. Test backends cannot touch the guest OS.
pub trait Backend {
    fn package(&mut self, name: &str, deadline: Instant) -> Result<Option<String>, String>;
    fn file(&mut self, path: &str, deadline: Instant) -> Result<FileObservation, String>;
    fn service(&mut self, name: &str, deadline: Instant) -> Result<ServiceObservation, String>;
    fn sysctl(&mut self, key: &str, deadline: Instant) -> Result<Option<String>, String>;
    fn apply_package(&mut self, package: &Package, deadline: Instant) -> Result<(), String>;
    fn apply_file(&mut self, file: &File, deadline: Instant) -> Result<(), String>;
    fn apply_service(&mut self, service: &Service, deadline: Instant) -> Result<(), String>;
    fn apply_sysctl(&mut self, sysctl: &Sysctl, deadline: Instant) -> Result<(), String>;
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    generation: i64,
    digest: String,
    state: String,
    error: Option<String>,
    #[serde(default)]
    failed_item: Option<ItemFailure>,
}

/// One instance is held under the VM daemon's mutex: concurrent host requests
/// serialize both generation decisions and guest effects.
pub struct Converger {
    journal: PathBuf,
    budget: Duration,
}
impl Converger {
    pub fn new(journal: PathBuf, budget: Duration) -> Self {
        Self { journal, budget }
    }
    fn load(&self) -> Result<Option<Journal>, String> {
        use std::io::Read;
        let file = match std::fs::File::open(&self.journal) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err("guest convergence journal is unreadable".into()),
        };
        let mut bytes = Vec::new();
        file.take(16385)
            .read_to_end(&mut bytes)
            .map_err(|_| "guest convergence journal is unreadable")?;
        if bytes.len() > 16384 {
            return Err("guest convergence journal is oversized".into());
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| "guest convergence journal is corrupt")?;
        if journal.generation < 0
            || journal.digest.len() != 64
            || !journal.digest.bytes().all(|b| b.is_ascii_hexdigit())
            || !["converged", "failed", "applying"].contains(&journal.state.as_str())
            || (journal.state == "failed") != journal.error.is_some()
        {
            return Err("guest convergence journal is corrupt".into());
        }
        Ok(Some(journal))
    }
    fn save(&self, journal: &Journal) -> Result<(), String> {
        let bytes =
            serde_json::to_vec(journal).map_err(|_| "serialize guest convergence journal")?;
        atomic_write(&self.journal, &bytes, 0o600)
            .map_err(|_| "persist guest convergence journal".into())
    }
    pub fn converge(
        &mut self,
        generation: i64,
        config: Option<GuestConfig>,
        backend: &mut impl Backend,
    ) -> Observation {
        let mut observation = Observation::empty(generation);
        let config = config.unwrap_or_default();
        if generation < 0 || config.validate().is_err() {
            observation.fail("invalid guest configuration".into());
            return observation;
        }
        if config
            .files
            .iter()
            .any(|f| Path::new(&f.path) == self.journal)
        {
            observation.fail("guest convergence journal path is reserved".into());
            return observation;
        }
        let digest = hash(&serde_json::to_vec(&config).expect("serializable config"));
        let previous = match self.load() {
            Ok(p) => p,
            Err(e) => {
                observation.fail(e);
                return observation;
            }
        };
        if let Some(ref p) = previous {
            if generation < p.generation {
                observation.fail("stale guest configuration generation".into());
                return observation;
            }
            if generation == p.generation && digest != p.digest {
                observation.fail("guest configuration changed without a new VM generation".into());
                return observation;
            }
        }
        let deadline = match Instant::now().checked_add(self.budget) {
            Some(d) => d,
            None => {
                observation.fail("invalid convergence budget".into());
                return observation;
            }
        };
        let retained_error = previous
            .as_ref()
            .filter(|p| p.generation == generation && p.state != "converged")
            .map(|p| {
                p.error.clone().unwrap_or_else(|| {
                    "guest convergence interrupted; submit a new VM generation to retry".into()
                })
            });
        // The intent has no secrets on disk. Write-ahead evidence makes a crash
        // during package installation terminal, rather than a fresh retry budget.
        if retained_error.is_none() {
            if let Err(e) = self.save(&Journal {
                generation,
                digest: digest.clone(),
                state: "applying".into(),
                error: None,
                failed_item: None,
            }) {
                observation.fail(e);
                return observation;
            }
        }
        let result = self.realize(
            &config,
            backend,
            deadline,
            retained_error.is_none(),
            &mut observation,
        );
        if let Some(error) = retained_error {
            observation.fail(error);
            observation.failed_item = previous.as_ref().and_then(|p| p.failed_item.clone());
            return observation;
        }
        if let Err(e) = result {
            observation.fail(e.reason.clone());
            observation.failed_item = Some(e);
        }
        let journal = Journal {
            generation,
            digest,
            state: if observation.error.is_some() {
                "failed"
            } else {
                "converged"
            }
            .into(),
            error: observation.error.clone(),
            failed_item: observation.failed_item.clone(),
        };
        if let Err(e) = self.save(&journal) {
            observation.fail(e);
        }
        observation
    }
    fn realize(
        &self,
        config: &GuestConfig,
        backend: &mut impl Backend,
        deadline: Instant,
        apply: bool,
        observed: &mut Observation,
    ) -> Result<(), ItemFailure> {
        // Always collect pre-apply evidence, including on a sticky failure.
        for e in &config.packages {
            observed.packages.push(PackageObservation {
                name: e.name.clone(),
                version: backend
                    .package(&e.name, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Packages, &e.name, reason))?,
            });
        }
        for e in &config.files {
            observed.files.push(
                backend
                    .file(&e.path, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Files, &e.path, reason))?,
            );
        }
        for e in &config.services {
            observed.services.push(
                backend
                    .service(&e.name, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Services, &e.name, reason))?,
            );
        }
        for e in &config.sysctls {
            observed.sysctls.push(SysctlObservation {
                key: e.key.clone(),
                value: backend
                    .sysctl(&e.key, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Sysctls, &e.key, reason))?,
            });
        }
        if !apply {
            return Ok(());
        }
        for (entry, fact) in config.packages.iter().zip(observed.packages.iter_mut()) {
            if fact.version.is_some() != (entry.state == PackageState::Present) {
                backend
                    .apply_package(entry, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Packages, &entry.name, reason))?;
                fact.version = backend
                    .package(&entry.name, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Packages, &entry.name, reason))?;
                if fact.version.is_some() != (entry.state == PackageState::Present) {
                    return Err(ItemFailure::new(
                        Section::Packages,
                        &entry.name,
                        "package read-back differs from desired state".into(),
                    ));
                }
            }
        }
        for (entry, fact) in config.files.iter().zip(observed.files.iter_mut()) {
            if fact.sha256.as_deref() != Some(&hash(entry.content.as_bytes()))
                || fact.mode.as_deref() != Some(&entry.mode)
            {
                backend
                    .apply_file(entry, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Files, &entry.path, reason))?;
                *fact = backend
                    .file(&entry.path, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Files, &entry.path, reason))?;
                if fact.sha256.as_deref() != Some(&hash(entry.content.as_bytes()))
                    || fact.mode.as_deref() != Some(&entry.mode)
                {
                    return Err(ItemFailure::new(
                        Section::Files,
                        &entry.path,
                        "file read-back differs from desired state".into(),
                    ));
                }
            }
        }
        for (entry, fact) in config.services.iter().zip(observed.services.iter_mut()) {
            if fact.enabled != Some(entry.enabled) {
                backend
                    .apply_service(entry, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Services, &entry.name, reason))?;
                *fact = backend
                    .service(&entry.name, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Services, &entry.name, reason))?;
                if fact.enabled != Some(entry.enabled) {
                    return Err(ItemFailure::new(
                        Section::Services,
                        &entry.name,
                        "service read-back differs from desired state".into(),
                    ));
                }
            }
        }
        for (entry, fact) in config.sysctls.iter().zip(observed.sysctls.iter_mut()) {
            if fact.value.as_deref().map(normalize) != Some(normalize(&entry.value)) {
                backend
                    .apply_sysctl(entry, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Sysctls, &entry.key, reason))?;
                fact.value = backend
                    .sysctl(&entry.key, deadline)
                    .map_err(|reason| ItemFailure::new(Section::Sysctls, &entry.key, reason))?;
                if fact.value.as_deref().map(normalize) != Some(normalize(&entry.value)) {
                    return Err(ItemFailure::new(
                        Section::Sysctls,
                        &entry.key,
                        "sysctl read-back differs from desired state".into(),
                    ));
                }
            }
        }
        Ok(())
    }
}
fn normalize(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Atomic publish, including permission bits, with durable directory evidence.
/// The temporary is create_new and never follows an existing symlink.
pub fn atomic_write(path: &Path, content: &[u8], mode: u32) -> std::io::Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "no parent"))?;
    std::fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".strato-{}-{}",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(mode);
        let mut file = options.open(&temporary)?;
        file.write_all(content)?;
        #[cfg(unix)]
        file.set_permissions(std::fs::Permissions::from_mode(mode))?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)?;
        std::fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}
static TEMP_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                "strato-convergence-test-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            )))
        }
        fn engine(&self) -> Converger {
            Converger::new(self.0.join("journal.json"), Duration::from_secs(1))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[derive(Default)]
    struct Fake {
        packages: BTreeMap<String, String>,
        files: BTreeMap<String, FileObservation>,
        services: BTreeMap<String, ServiceObservation>,
        sysctls: BTreeMap<String, String>,
        effects: Vec<String>,
        fail_package: bool,
        fail_file: bool,
    }
    impl Backend for Fake {
        fn package(&mut self, n: &str, _: Instant) -> Result<Option<String>, String> {
            Ok(self.packages.get(n).cloned())
        }
        fn file(&mut self, p: &str, _: Instant) -> Result<FileObservation, String> {
            if self.fail_file {
                return Err("managed file is unreadable".into());
            }
            Ok(self.files.get(p).cloned().unwrap_or(FileObservation {
                path: p.into(),
                sha256: None,
                mode: None,
            }))
        }
        fn service(&mut self, n: &str, _: Instant) -> Result<ServiceObservation, String> {
            Ok(self.services.get(n).cloned().unwrap_or(ServiceObservation {
                name: n.into(),
                enabled: Some(false),
                active_state: Some("inactive".into()),
            }))
        }
        fn sysctl(&mut self, k: &str, _: Instant) -> Result<Option<String>, String> {
            Ok(self.sysctls.get(k).cloned())
        }
        fn apply_package(&mut self, p: &Package, _: Instant) -> Result<(), String> {
            self.effects.push("package".into());
            if self.fail_package {
                return Err("package operation budget exhausted".into());
            }
            if p.state == PackageState::Present {
                self.packages.insert(p.name.clone(), "1.2.3".into());
            } else {
                self.packages.remove(&p.name);
            }
            Ok(())
        }
        fn apply_file(&mut self, f: &File, _: Instant) -> Result<(), String> {
            self.effects.push("file".into());
            self.files.insert(
                f.path.clone(),
                FileObservation {
                    path: f.path.clone(),
                    sha256: Some(hash(f.content.as_bytes())),
                    mode: Some(f.mode.clone()),
                },
            );
            Ok(())
        }
        fn apply_service(&mut self, s: &Service, _: Instant) -> Result<(), String> {
            self.effects.push("service".into());
            self.services.insert(
                s.name.clone(),
                ServiceObservation {
                    name: s.name.clone(),
                    enabled: Some(s.enabled),
                    active_state: Some("inactive".into()),
                },
            );
            Ok(())
        }
        fn apply_sysctl(&mut self, s: &Sysctl, _: Instant) -> Result<(), String> {
            self.effects.push("sysctl".into());
            self.sysctls.insert(s.key.clone(), s.value.clone());
            Ok(())
        }
    }
    fn config() -> GuestConfig {
        GuestConfig {
            packages: vec![Package {
                name: "curl".into(),
                state: PackageState::Present,
            }],
            files: vec![File {
                path: "/etc/example.conf".into(),
                content: "private contents".into(),
                mode: "0640".into(),
            }],
            services: vec![Service {
                name: "example.service".into(),
                enabled: true,
            }],
            sysctls: vec![Sysctl {
                key: "net.ipv4.ip_forward".into(),
                value: "1".into(),
            }],
        }
    }
    #[test]
    fn realizes_read_back_noop_replay_and_restart_then_repairs_drift() {
        let fixture = Fixture::new();
        let mut fake = Fake::default();
        let c = config();
        let observed = fixture.engine().converge(7, Some(c.clone()), &mut fake);
        assert_eq!(observed.status, Status::Converged);
        assert_eq!(observed.packages[0].version.as_deref(), Some("1.2.3"));
        assert_eq!(
            observed.files[0].sha256.as_deref(),
            Some(hash(b"private contents").as_str())
        );
        assert_eq!(
            observed.services[0].active_state.as_deref(),
            Some("inactive")
        );
        assert_eq!(fake.effects, ["package", "file", "service", "sysctl"]);
        fake.effects.clear();
        assert_eq!(
            fixture
                .engine()
                .converge(7, Some(c.clone()), &mut fake)
                .status,
            Status::Converged
        );
        assert!(fake.effects.is_empty());
        fake.files.clear();
        assert_eq!(
            fixture.engine().converge(7, Some(c), &mut fake).status,
            Status::Converged
        );
        assert_eq!(fake.effects, ["file"]);
        let journal = std::fs::read_to_string(fixture.0.join("journal.json")).unwrap();
        assert!(!journal.contains("private contents"));
    }
    #[test]
    fn failures_are_terminal_across_restart_and_new_generation_recovers() {
        let fixture = Fixture::new();
        let mut fake = Fake {
            fail_package: true,
            ..Fake::default()
        };
        let failure = fixture.engine().converge(7, Some(config()), &mut fake);
        assert_eq!(failure.status, Status::Failed);
        let failed_item = failure.failed_item.clone().unwrap();
        assert_eq!(failed_item.section, Section::Packages);
        assert_eq!(failed_item.identity, "curl");
        assert_eq!(fake.effects, ["package"]); // no subsequent file/service effects
        fake.fail_package = false;
        fake.effects.clear();
        assert_eq!(
            fixture
                .engine()
                .converge(7, Some(config()), &mut fake)
                .error,
            failure.error
        );
        assert!(fake.effects.is_empty());
        assert_eq!(
            fixture
                .engine()
                .converge(8, Some(config()), &mut fake)
                .status,
            Status::Converged
        );
    }
    #[test]
    fn interrupted_apply_is_terminal_and_older_or_changed_generation_cannot_mutate() {
        let fixture = Fixture::new();
        let mut fake = Fake::default();
        let c = config();
        fixture
            .engine()
            .save(&Journal {
                generation: 7,
                digest: hash(&serde_json::to_vec(&c).unwrap()),
                state: "applying".into(),
                error: None,
                failed_item: None,
            })
            .unwrap();
        assert!(fixture
            .engine()
            .converge(7, Some(c.clone()), &mut fake)
            .error
            .unwrap()
            .contains("interrupted"));
        assert!(fixture
            .engine()
            .converge(6, Some(c), &mut fake)
            .error
            .unwrap()
            .contains("stale"));
        assert!(fixture
            .engine()
            .converge(7, None, &mut fake)
            .error
            .unwrap()
            .contains("without a new"));
        assert!(fake.effects.is_empty());
    }
    #[test]
    fn withdrawals_do_not_reverse_changes_and_absent_packages_are_removed_once() {
        let fixture = Fixture::new();
        let mut fake = Fake::default();
        fixture.engine().converge(1, Some(config()), &mut fake);
        fake.effects.clear();
        assert_eq!(
            fixture.engine().converge(2, None, &mut fake).status,
            Status::Converged
        );
        assert!(fake.effects.is_empty());
        assert!(fake.packages.contains_key("curl"));
        assert!(!fake.files.is_empty());
        let c = GuestConfig {
            packages: vec![Package {
                name: "curl".into(),
                state: PackageState::Absent,
            }],
            ..GuestConfig::default()
        };
        fixture.engine().converge(3, Some(c.clone()), &mut fake);
        fixture.engine().converge(3, Some(c), &mut fake);
        assert_eq!(fake.effects, ["package"]);
        assert!(!fake.packages.contains_key("curl"));
    }
    #[test]
    fn observation_failure_names_the_exact_row_without_claiming_other_rows_failed() {
        let fixture = Fixture::new();
        let mut fake = Fake {
            fail_file: true,
            ..Fake::default()
        };
        let result = fixture.engine().converge(7, Some(config()), &mut fake);
        let item = result.failed_item.unwrap();
        assert_eq!(item.section, Section::Files);
        assert_eq!(item.identity, "/etc/example.conf");
        assert_eq!(result.error.as_deref(), Some(item.reason.as_str()));
        assert!(result.files.is_empty());
        assert_eq!(result.packages.len(), 1);
        assert!(fake.effects.is_empty());
    }
    #[test]
    fn corrupt_journal_and_invalid_intent_fail_closed() {
        let fixture = Fixture::new();
        let mut fake = Fake::default();
        std::fs::create_dir_all(&fixture.0).unwrap();
        std::fs::write(fixture.0.join("journal.json"), "bad").unwrap();
        assert!(fixture
            .engine()
            .converge(1, Some(config()), &mut fake)
            .error
            .unwrap()
            .contains("corrupt"));
        let mut c = config();
        c.files[0].path = "/etc/../bad".into();
        assert_eq!(
            fixture.engine().converge(2, Some(c), &mut fake).status,
            Status::Failed
        );
        assert!(fake.effects.is_empty());
    }
    #[test]
    fn strict_schema_and_swift_limits_are_mirrored() {
        assert!(
            serde_json::from_str::<GuestConfig>(r#"{"packages":[],"files":[],"services":[]}"#)
                .is_err()
        );
        assert!(serde_json::from_str::<GuestConfig>(
            r#"{"packages":[],"files":[],"services":[],"sysctls":[],"commands":[]}"#
        )
        .is_err());
        let mut c = config();
        c.packages.push(c.packages[0].clone());
        assert!(c.validate().is_err());
        let mut c = config();
        c.files[0].mode = "4755".into();
        assert!(c.validate().is_err());
        let mut c = config();
        c.files[0].content = "x".repeat(65537);
        assert!(c.validate().is_err());
        let mut c = config();
        c.packages[0].name = "-option".into();
        assert!(c.validate().is_err());
    }
}
