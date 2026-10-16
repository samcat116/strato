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
        let (bytes, _) = match read_regular_file(&self.journal, 16384) {
            Ok(Some(file)) => file,
            Ok(None) => return Ok(None),
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                return Err("guest convergence journal is oversized".into())
            }
            Err(_) => return Err("guest convergence journal is unreadable".into()),
        };
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

/// Read one regular file without following any path component. The returned
/// mode and bytes come from the same descriptor.
pub fn read_regular_file(path: &Path, limit: usize) -> std::io::Result<Option<(Vec<u8>, u32)>> {
    platform_fs::read_regular_file(path, limit)
}

/// Open one existing regular file for writing without following any path
/// component. Used for procfs sysctls as well as ordinary files.
#[cfg(target_os = "linux")]
pub fn open_regular_file_for_write(path: &Path) -> std::io::Result<std::fs::File> {
    platform_fs::open_regular_file_for_write(path)
}

/// Atomic publish, including permission bits, with durable directory evidence.
/// Linux resolves every component relative to pinned directory descriptors.
pub fn atomic_write(path: &Path, content: &[u8], mode: u32) -> std::io::Result<()> {
    platform_fs::atomic_write(path, content, mode)
}
#[cfg(test)]
static TEMP_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(target_os = "linux")]
mod platform_fs {
    #[cfg(test)]
    use super::TEMP_SEQUENCE;
    use std::ffi::{CString, OsStr, OsString};
    use std::io::{self, Read, Write};
    use std::mem::MaybeUninit;
    use std::os::fd::{AsRawFd, FromRawFd, RawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::{Component, Path};
    #[cfg(test)]
    use std::sync::atomic::Ordering;

    fn invalid(message: &'static str) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidInput, message)
    }

    fn cstring(value: &OsStr) -> io::Result<CString> {
        CString::new(value.as_bytes()).map_err(|_| invalid("path contains NUL"))
    }

    fn open_directory_at(parent: RawFd, name: &OsStr, create: bool) -> io::Result<std::fs::File> {
        let name = cstring(name)?;
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW;
        // SAFETY: parent is live and name is a NUL-terminated component.
        let mut fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
        if fd < 0 && create && io::Error::last_os_error().kind() == io::ErrorKind::NotFound {
            // SAFETY: arguments satisfy mkdirat; EEXIST is resolved by the
            // no-follow open below, so a racing symlink is still rejected.
            let result = unsafe { libc::mkdirat(parent, name.as_ptr(), 0o777) };
            if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: same live descriptor and component as above.
            fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
        }
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            // SAFETY: successful openat returned a newly owned descriptor.
            Ok(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    }

    fn open_parent(path: &Path, create: bool) -> io::Result<(std::fs::File, OsString)> {
        let mut components = path.components();
        if components.next() != Some(Component::RootDir) {
            return Err(invalid("path must be absolute"));
        }
        let mut names = Vec::new();
        for component in components {
            match component {
                Component::Normal(name) => names.push(name.to_os_string()),
                _ => return Err(invalid("path must be canonical")),
            }
        }
        let name = names
            .pop()
            .ok_or_else(|| invalid("path has no file name"))?;
        let root = CString::new("/").expect("static path");
        // SAFETY: root is a valid NUL-terminated path.
        let root_fd = unsafe {
            libc::open(
                root.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if root_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful open returned a newly owned descriptor.
        let mut directory = unsafe { std::fs::File::from_raw_fd(root_fd) };
        for component in names {
            directory = open_directory_at(directory.as_raw_fd(), &component, create)?;
        }
        Ok((directory, name))
    }

    fn open_final(
        directory: &std::fs::File,
        name: &OsStr,
        flags: libc::c_int,
        mode: libc::mode_t,
    ) -> io::Result<std::fs::File> {
        let name = cstring(name)?;
        // SAFETY: directory and name remain live for the call.
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                mode,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            // SAFETY: successful openat returned a newly owned descriptor.
            Ok(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    }

    fn require_regular(file: &std::fs::File) -> io::Result<()> {
        if file.metadata()?.is_file() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::Other,
                "path is not a regular file",
            ))
        }
    }

    fn read_regular_at(
        directory: &std::fs::File,
        name: &OsStr,
        limit: usize,
    ) -> io::Result<Option<(Vec<u8>, u32)>> {
        let mut file = match open_final(directory, name, libc::O_RDONLY | libc::O_NONBLOCK, 0) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        require_regular(&file)?;
        let mode = file.metadata()?.permissions().mode() & 0o7777;
        let mut bytes = Vec::new();
        (&mut file)
            .take(limit.saturating_add(1) as u64)
            .read_to_end(&mut bytes)?;
        if bytes.len() > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "file exceeds byte limit",
            ));
        }
        Ok(Some((bytes, mode)))
    }

    pub(super) fn read_regular_file(
        path: &Path,
        limit: usize,
    ) -> io::Result<Option<(Vec<u8>, u32)>> {
        let (directory, name) = match open_parent(path, false) {
            Ok(result) => result,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        read_regular_at(&directory, &name, limit)
    }

    pub(super) fn open_regular_file_for_write(path: &Path) -> io::Result<std::fs::File> {
        let (directory, name) = open_parent(path, false)?;
        let file = open_final(&directory, &name, libc::O_WRONLY | libc::O_NONBLOCK, 0)?;
        require_regular(&file)?;
        Ok(file)
    }

    fn target_is_regular_or_missing(directory: &std::fs::File, name: &OsStr) -> io::Result<()> {
        let name = cstring(name)?;
        let mut stat = MaybeUninit::<libc::stat>::uninit();
        // SAFETY: pointers are valid; AT_SYMLINK_NOFOLLOW inspects the entry.
        let result = unsafe {
            libc::fstatat(
                directory.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::NotFound {
                Ok(())
            } else {
                Err(error)
            };
        }
        // SAFETY: fstatat initialized stat on success.
        let stat = unsafe { stat.assume_init() };
        if stat.st_mode & libc::S_IFMT == libc::S_IFREG {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::Other,
                "target is not a regular file",
            ))
        }
    }

    fn staging_name() -> io::Result<OsString> {
        let mut random = [0_u8; 16];
        let mut offset = 0;
        while offset < random.len() {
            // SAFETY: the remaining slice is valid writable memory.
            let count = unsafe {
                libc::getrandom(
                    random[offset..].as_mut_ptr().cast(),
                    random.len() - offset,
                    0,
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if count == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "getrandom returned no bytes",
                ));
            }
            offset += count as usize;
        }
        let mut name = String::from(".strato-");
        for byte in random {
            use std::fmt::Write as _;
            write!(&mut name, "{byte:02x}").expect("write to string");
        }
        Ok(name.into())
    }

    fn entry_matches_file(
        directory: &std::fs::File,
        name: &CString,
        file: &std::fs::File,
    ) -> io::Result<bool> {
        let expected = file.metadata()?;
        let mut actual = MaybeUninit::<libc::stat>::uninit();
        // SAFETY: pointers are valid; AT_SYMLINK_NOFOLLOW inspects the entry.
        if unsafe {
            libc::fstatat(
                directory.as_raw_fd(),
                name.as_ptr(),
                actual.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } < 0
        {
            return Ok(false);
        }
        // SAFETY: fstatat initialized actual on success.
        let actual = unsafe { actual.assume_init() };
        Ok(actual.st_dev == expected.dev() && actual.st_ino == expected.ino())
    }

    fn create_private_staging_directory(
        directory: &std::fs::File,
        mut next_name: impl FnMut() -> io::Result<OsString>,
    ) -> io::Result<(std::fs::File, OsString)> {
        for _ in 0..64 {
            let name = next_name()?;
            let name_c = cstring(&name)?;
            // SAFETY: the parent descriptor and component remain live. The
            // mode makes the payload namespace inaccessible to non-root guest
            // processes even when the managed parent is writable by them.
            if unsafe { libc::mkdirat(directory.as_raw_fd(), name_c.as_ptr(), 0o700) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::AlreadyExists {
                    continue;
                }
                return Err(error);
            }
            let staging = open_directory_at(directory.as_raw_fd(), &name, false)?;
            let metadata = staging.metadata()?;
            if metadata.uid() != unsafe { libc::geteuid() }
                || metadata.permissions().mode() & 0o7777 != 0o700
            {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "staging directory ownership changed",
                ));
            }
            return Ok((staging, name));
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "staging names exhausted",
        ))
    }

    fn parent_cleanup_is_safe(directory: &std::fs::File) -> io::Result<bool> {
        let mode = directory.metadata()?.permissions().mode();
        // In a non-writable parent, only root can swap the staging entry. A
        // sticky writable parent (for example /tmp) likewise protects the
        // root-owned staging directory. Root can already replace the managed
        // target directly and is outside this boundary.
        Ok(mode & 0o022 == 0 || mode & 0o1000 != 0)
    }

    fn cleanup_private_staging_directory(
        directory: &std::fs::File,
        staging: &std::fs::File,
        name: &CString,
    ) {
        if !parent_cleanup_is_safe(directory).unwrap_or(false)
            || !entry_matches_file(directory, name, staging).unwrap_or(false)
        {
            return;
        }
        // SAFETY: untrusted processes cannot replace this entry in a parent
        // accepted by parent_cleanup_is_safe, and it identifies our opened,
        // now-empty directory.
        let _ = unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) };
    }

    fn atomic_write_at_with_names_and_hook(
        directory: &std::fs::File,
        target: &OsStr,
        content: &[u8],
        mode: u32,
        mut next_name: impl FnMut() -> io::Result<OsString>,
        before_publish: impl FnOnce(&std::fs::File, &OsStr) -> io::Result<()>,
    ) -> io::Result<()> {
        target_is_regular_or_missing(directory, target)?;
        let target_c = cstring(target)?;
        let (staging, staging_name) = create_private_staging_directory(directory, &mut next_name)?;
        let staging_name_c = cstring(&staging_name)?;
        let payload = CString::new("payload").expect("static name");
        let mut file = match open_final(
            &staging,
            OsStr::new("payload"),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            mode,
        ) {
            Ok(file) => file,
            Err(error) => {
                cleanup_private_staging_directory(directory, &staging, &staging_name_c);
                return Err(error);
            }
        };
        let mut published = false;
        let result = (|| {
            file.write_all(content)?;
            file.set_permissions(std::fs::Permissions::from_mode(mode))?;
            file.sync_all()?;
            before_publish(&staging, &staging_name)?;
            // SAFETY: the source lives in the root-owned 0700 directory
            // referenced by `staging`, so an untrusted process cannot replace
            // it between validation and this rename. The destination parent is
            // the pinned directory resolved from the managed path.
            if unsafe {
                libc::renameat(
                    staging.as_raw_fd(),
                    payload.as_ptr(),
                    directory.as_raw_fd(),
                    target_c.as_ptr(),
                )
            } < 0
            {
                return Err(io::Error::last_os_error());
            }
            published = true;
            cleanup_private_staging_directory(directory, &staging, &staging_name_c);
            directory.sync_all()
        })();
        if !published {
            // SAFETY: payload is inside the descriptor-pinned private
            // directory. Removing it cannot affect any replacement entry an
            // attacker may have installed in the managed parent.
            let _ = unsafe { libc::unlinkat(staging.as_raw_fd(), payload.as_ptr(), 0) };
            cleanup_private_staging_directory(directory, &staging, &staging_name_c);
        }
        result
    }

    fn atomic_write_at_with_names(
        directory: &std::fs::File,
        target: &OsStr,
        content: &[u8],
        mode: u32,
        next_name: impl FnMut() -> io::Result<OsString>,
    ) -> io::Result<()> {
        atomic_write_at_with_names_and_hook(directory, target, content, mode, next_name, |_, _| {
            Ok(())
        })
    }

    fn atomic_write_at(
        directory: &std::fs::File,
        target: &OsStr,
        content: &[u8],
        mode: u32,
    ) -> io::Result<()> {
        atomic_write_at_with_names(directory, target, content, mode, staging_name)
    }

    pub(super) fn atomic_write(path: &Path, content: &[u8], mode: u32) -> io::Result<()> {
        let (directory, name) = open_parent(path, true)?;
        atomic_write_at(&directory, &name, content, mode)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::os::unix::fs::symlink;

        fn fixture(name: &str) -> std::path::PathBuf {
            std::env::temp_dir().join(format!(
                "strato-secure-fs-{name}-{}-{}",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ))
        }

        #[test]
        fn pinned_parent_prevents_ancestor_symlink_redirect() {
            let root = fixture("ancestor");
            let managed = root.join("managed");
            let outside = root.join("outside");
            std::fs::create_dir_all(&managed).unwrap();
            std::fs::create_dir_all(&outside).unwrap();
            std::fs::write(managed.join("config"), "inside").unwrap();
            std::fs::write(outside.join("config"), "outside").unwrap();
            std::fs::set_permissions(
                managed.join("config"),
                std::fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            let (parent, target) = open_parent(&managed.join("config"), false).unwrap();
            std::fs::rename(&managed, root.join("pinned")).unwrap();
            symlink(&outside, &managed).unwrap();
            let (bytes, mode) = read_regular_at(&parent, &target, 64).unwrap().unwrap();
            assert_eq!(bytes, b"inside");
            assert_eq!(mode, 0o600);
            atomic_write_at(&parent, &target, b"updated", 0o600).unwrap();
            assert_eq!(
                std::fs::read(root.join("pinned/config")).unwrap(),
                b"updated"
            );
            assert_eq!(std::fs::read(outside.join("config")).unwrap(), b"outside");
            std::fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn staging_collision_is_never_removed() {
            let root = fixture("collision");
            std::fs::create_dir_all(&root).unwrap();
            let collision = root.join(".strato-collision");
            std::fs::write(&collision, "unowned").unwrap();
            let (parent, target) = open_parent(&root.join("target"), false).unwrap();
            let mut names = [
                OsString::from(".strato-collision"),
                OsString::from(".strato-owned"),
            ]
            .into_iter();
            atomic_write_at_with_names(&parent, &target, b"managed", 0o600, || {
                names
                    .next()
                    .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "no test name"))
            })
            .unwrap();
            assert_eq!(std::fs::read(collision).unwrap(), b"unowned");
            assert_eq!(std::fs::read(root.join("target")).unwrap(), b"managed");
            assert!(!root.join(".strato-owned").exists());
            std::fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn staging_parent_entry_swap_cannot_publish_or_delete_replacement() {
            let root = fixture("staging-swap");
            std::fs::create_dir_all(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
            let (parent, target) = open_parent(&root.join("target"), false).unwrap();
            let staging_name = OsString::from(".strato-private");
            atomic_write_at_with_names_and_hook(
                &parent,
                &target,
                b"managed",
                0o600,
                || Ok(staging_name.clone()),
                |_, name| {
                    std::fs::rename(root.join(name), root.join("moved-private"))?;
                    std::fs::create_dir(root.join(name))?;
                    std::fs::write(root.join(name).join("replacement"), b"unowned")
                },
            )
            .unwrap();

            assert_eq!(std::fs::read(root.join("target")).unwrap(), b"managed");
            assert_eq!(
                std::fs::read(root.join(&staging_name).join("replacement")).unwrap(),
                b"unowned"
            );
            assert!(root.join("moved-private").is_dir());
            std::fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn failed_publish_cleans_only_the_descriptor_pinned_payload() {
            let root = fixture("staging-failure");
            std::fs::create_dir_all(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
            let (parent, target) = open_parent(&root.join("target"), false).unwrap();
            let staging_name = OsString::from(".strato-private");
            let error = atomic_write_at_with_names_and_hook(
                &parent,
                &target,
                b"managed",
                0o600,
                || Ok(staging_name.clone()),
                |_, name| {
                    std::fs::rename(root.join(name), root.join("moved-private"))?;
                    std::fs::create_dir(root.join(name))?;
                    std::fs::write(root.join(name).join("replacement"), b"unowned")?;
                    Err(io::Error::new(io::ErrorKind::Other, "injected failure"))
                },
            )
            .unwrap_err();

            assert_eq!(error.to_string(), "injected failure");
            assert!(!root.join("target").exists());
            assert_eq!(
                std::fs::read(root.join(&staging_name).join("replacement")).unwrap(),
                b"unowned"
            );
            assert!(std::fs::read_dir(root.join("moved-private"))
                .unwrap()
                .next()
                .is_none());
            std::fs::remove_dir_all(root).unwrap();
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod platform_fs {
    use std::io;
    use std::path::Path;

    pub(super) fn read_regular_file(
        _path: &Path,
        _limit: usize,
    ) -> io::Result<Option<(Vec<u8>, u32)>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure guest convergence requires Linux descriptor-relative paths",
        ))
    }

    pub(super) fn atomic_write(_path: &Path, _content: &[u8], _mode: u32) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "secure guest convergence requires Linux descriptor-relative paths",
        ))
    }
}

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
    #[cfg(target_os = "linux")]
    #[test]
    fn journal_symlink_is_rejected_without_touching_its_target() {
        use std::os::unix::fs::symlink;

        let fixture = Fixture::new();
        let mut fake = Fake::default();
        std::fs::create_dir_all(&fixture.0).unwrap();
        let target = fixture.0.join("outside.json");
        std::fs::write(&target, "sentinel").unwrap();
        symlink(&target, fixture.0.join("journal.json")).unwrap();
        let observation = fixture.engine().converge(1, Some(config()), &mut fake);
        assert!(observation.error.unwrap().contains("unreadable"));
        assert_eq!(std::fs::read_to_string(target).unwrap(), "sentinel");
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
