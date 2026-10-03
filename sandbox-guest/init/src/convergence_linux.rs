//! Linux realization. Production effects are isolated from the fake-backend
//! convergence tests; no test installs a package or changes a host service.
use crate::convergence::*;
use crate::convergence_command::{self, CommandFailure};
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

pub struct LinuxBackend;
fn check(deadline: Instant) -> Result<Duration, String> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err("guest convergence budget exhausted".into())
    } else {
        Ok(remaining)
    }
}
fn command(
    program: &str,
    args: &[&str],
    deadline: Instant,
    package: bool,
) -> Result<String, String> {
    let budget = check(deadline)?.min(if package {
        Duration::from_secs(120)
    } else {
        Duration::from_secs(10)
    });
    let mut cmd = Command::new(program);
    cmd.args(args)
        .env("LC_ALL", "C")
        .env("DEBIAN_FRONTEND", "noninteractive");
    let output = convergence_command::run(&mut cmd, budget, 65536).map_err(|e| -> String {
        match e {
            CommandFailure::TimedOut if package => {
                "package operation budget exhausted (mirror or package manager unavailable)".into()
            }
            CommandFailure::TimedOut => "guest observation/operation budget exhausted".into(),
            CommandFailure::Exit(Some(1)) if !package => "not_found".into(),
            _ if package => {
                "package operation failed (package manager or mirror unavailable)".into()
            }
            _ => "guest observation/operation failed".into(),
        }
    })?;
    String::from_utf8(output.stdout)
        .map(|s| s.trim().to_string())
        .map_err(|_| "non-UTF8 guest observation".into())
}
fn read(path: &Path, limit: u64, deadline: Instant) -> Result<Option<String>, String> {
    check(deadline)?;
    let (bytes, _) = match read_regular_file(path, limit as usize) {
        Ok(Some(file)) => file,
        Ok(None) => return Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
            return Err("managed file exceeds observation byte limit".into())
        }
        Err(_) => return Err("managed file is unreadable".into()),
    };
    check(deadline)?;
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| "managed file is not UTF-8".into())
}
fn bounded_package_version(
    result: Result<Option<String>, String>,
) -> Result<Option<String>, String> {
    match result {
        Err(error) if error == "not_found" => Ok(None),
        Ok(Some(version)) if version.is_empty() || version.len() > 255 => {
            Err("package observation exceeds byte limit".into())
        }
        other => other,
    }
}
impl Backend for LinuxBackend {
    fn package(&mut self, name: &str, deadline: Instant) -> Result<Option<String>, String> {
        let result = if Path::new("/usr/bin/dpkg-query").exists() {
            command(
                "/usr/bin/dpkg-query",
                &["-W", "-f=${db:Status-Status}\t${Version}", "--", name],
                deadline,
                false,
            )
            .map(|s| s.strip_prefix("installed\t").map(str::to_owned))
        } else if Path::new("/usr/bin/rpm").exists() {
            command(
                "/usr/bin/rpm",
                &["-q", "--qf", "%{VERSION}-%{RELEASE}", "--", name],
                deadline,
                false,
            )
            .map(Some)
        } else {
            return Err("unsupported guest package manager (requires dpkg/apt or rpm/dnf)".into());
        };
        bounded_package_version(result)
    }
    fn file(&mut self, path: &str, deadline: Instant) -> Result<FileObservation, String> {
        check(deadline)?;
        let file = read_regular_file(Path::new(path), 65536).map_err(|error| {
            if error.kind() == std::io::ErrorKind::InvalidData {
                "managed file exceeds observation byte limit"
            } else {
                "managed file is unreadable"
            }
        })?;
        check(deadline)?;
        let (sha256, mode) = match file {
            Some((content, mode)) => (Some(hash(&content)), Some(format!("{mode:04o}"))),
            None => (None, None),
        };
        Ok(FileObservation {
            path: path.into(),
            sha256,
            mode,
        })
    }
    fn service(&mut self, name: &str, deadline: Instant) -> Result<ServiceObservation, String> {
        // is-enabled commonly returns 1 for disabled/static units; distinguish
        // it by querying UnitFileState rather than treating all exit 1 as absent.
        let state = command(
            "/usr/bin/systemctl",
            &["show", "--property=UnitFileState", "--value", "--", name],
            deadline,
            false,
        )?;
        let enabled = match state.as_str() {
            "enabled" => Some(true),
            "enabled-runtime" | "disabled" | "static" | "masked" | "masked-runtime"
            | "indirect" | "alias" | "generated" | "transient" => Some(false),
            _ => None,
        };
        let active = command(
            "/usr/bin/systemctl",
            &["show", "--property=ActiveState", "--value", "--", name],
            deadline,
            false,
        )?;
        if state.len() > 64 || active.len() > 64 {
            return Err("service observation exceeds byte limit".into());
        }
        Ok(ServiceObservation {
            name: name.into(),
            enabled,
            active_state: if active.is_empty() {
                None
            } else {
                Some(active)
            },
        })
    }
    fn sysctl(&mut self, key: &str, deadline: Instant) -> Result<Option<String>, String> {
        read(
            Path::new(&format!("/proc/sys/{}", key.replace('.', "/"))),
            1024,
            deadline,
        )
        .map(|s| s.map(|v| v.trim().to_string()))
    }
    fn apply_package(&mut self, package: &Package, deadline: Instant) -> Result<(), String> {
        let operation = if package.state == PackageState::Present {
            "install"
        } else {
            "remove"
        };
        if Path::new("/usr/bin/apt-get").exists() {
            command(
                "/usr/bin/apt-get",
                &[
                    "-y",
                    "-o",
                    "Acquire::Retries=0",
                    "-o",
                    "Acquire::http::Timeout=30",
                    "-o",
                    "Acquire::https::Timeout=30",
                    "-o",
                    "DPkg::Lock::Timeout=10",
                    operation,
                    "--",
                    &package.name,
                ],
                deadline,
                true,
            )?;
        } else if Path::new("/usr/bin/dnf").exists() {
            command(
                "/usr/bin/dnf",
                &["-y", operation, "--", &package.name],
                deadline,
                true,
            )?;
        } else {
            return Err("unsupported guest package manager (requires apt or dnf)".into());
        }
        Ok(())
    }
    fn apply_file(&mut self, file: &File, deadline: Instant) -> Result<(), String> {
        check(deadline)?;
        atomic_write(
            Path::new(&file.path),
            file.content.as_bytes(),
            u32::from_str_radix(&file.mode, 8).map_err(|_| "invalid file mode")?,
        )
        .map_err(|_| "managed file atomic write failed".into())
    }
    fn apply_service(&mut self, service: &Service, deadline: Instant) -> Result<(), String> {
        command(
            "/usr/bin/systemctl",
            &[
                if service.enabled { "enable" } else { "disable" },
                "--",
                &service.name,
            ],
            deadline,
            false,
        )?;
        Ok(())
    }
    fn apply_sysctl(&mut self, sysctl: &Sysctl, deadline: Instant) -> Result<(), String> {
        check(deadline)?;
        let path = std::path::PathBuf::from(format!("/proc/sys/{}", sysctl.key.replace('.', "/")));
        let mut file = open_regular_file_for_write(&path).map_err(|_| "sysctl write refused")?;
        file.write_all(sysctl.value.as_bytes())
            .map_err(|_| "sysctl write failed".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn file_effects_are_atomic_have_requested_mode_and_reject_symlinks() {
        let root = std::env::temp_dir().join(format!(
            "strato-files-test-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        let path = root.join("nested/config");
        let entry = File {
            path: path.to_str().unwrap().into(),
            content: "configured\n".into(),
            mode: "0640".into(),
        };
        let mut backend = LinuxBackend;
        assert!(backend
            .file(&entry.path, deadline)
            .unwrap()
            .sha256
            .is_none());
        backend.apply_file(&entry, deadline).unwrap();
        let fact = backend.file(&entry.path, deadline).unwrap();
        assert_eq!(fact.sha256, Some(hash(b"configured\n")));
        assert_eq!(fact.mode.as_deref(), Some("0640"));
        let link = root.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(backend.file(link.to_str().unwrap(), deadline).is_err());
        let linked_entry = File {
            path: link.to_str().unwrap().into(),
            ..entry
        };
        assert!(backend.apply_file(&linked_entry, deadline).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "configured\n");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn package_failures_are_sanitized_and_budget_is_shared() {
        let result = command(
            "/bin/sh",
            &["-c", "printf secret >&2; exit 3"],
            Instant::now() + Duration::from_secs(2),
            true,
        );
        assert_eq!(
            result.unwrap_err(),
            "package operation failed (package manager or mirror unavailable)"
        );
        let start = Instant::now();
        assert_eq!(
            command(
                "/bin/sh",
                &["-c", "sleep 30"],
                start + Duration::from_millis(50),
                true
            )
            .unwrap_err(),
            "package operation budget exhausted (mirror or package manager unavailable)"
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn package_versions_match_the_observation_contract() {
        assert_eq!(
            bounded_package_version(Err("not_found".into())).unwrap(),
            None
        );
        assert_eq!(
            bounded_package_version(Ok(Some("v".repeat(255)))).unwrap(),
            Some("v".repeat(255))
        );
        assert_eq!(
            bounded_package_version(Ok(Some("v".repeat(256)))).unwrap_err(),
            "package observation exceeds byte limit"
        );
        assert!(bounded_package_version(Ok(Some(String::new()))).is_err());
    }
}
