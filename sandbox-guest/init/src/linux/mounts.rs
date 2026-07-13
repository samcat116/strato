//! Filesystem setup for the guest init (Linux only).
//!
//! The init boots from an initramfs (a ramfs the kernel unpacks and uses as the
//! initial root). It brings up the pseudo-filesystems it needs, mounts the
//! container rootfs from a block device, then transitions onto it. Because you
//! cannot `pivot_root` out of the initial ramfs, the transition uses the
//! `switch_root` technique — `MS_MOVE` the pseudo-filesystems onto the new
//! root, move the new root to `/`, and `chroot` — which is the initramfs-
//! correct form of the "pivot onto the container rootfs" the design calls for.

use nix::mount::{mount, MsFlags};
use std::fs;
use std::io::Read;
use std::path::Path;

use strato_sandbox_init::config::RootfsSpec;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const NEW_ROOT: &str = "/newroot";

/// Mount the pseudo-filesystems the init needs before it can do anything else:
/// `devtmpfs` on `/dev` (so block-device nodes like `/dev/vda` exist), `proc`,
/// and `sysfs`.
pub fn mount_early() -> Result<()> {
    // The kernel may already have mounted devtmpfs (CONFIG_DEVTMPFS_MOUNT);
    // mounting again is harmless, but tolerate an existing mount.
    ensure_dir("/dev")?;
    let _ = mount(
        Some("devtmpfs"),
        "/dev",
        Some("devtmpfs"),
        MsFlags::MS_NOSUID,
        Some("mode=0755"),
    );
    ensure_dir("/proc")?;
    mount(
        Some("proc"),
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        NO_DATA,
    )?;
    ensure_dir("/sys")?;
    mount(
        Some("sysfs"),
        "/sys",
        Some("sysfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        NO_DATA,
    )?;
    Ok(())
}

/// Read the raw config drive (e.g. `/dev/vdb`) in full. The device has no
/// filesystem — the JSON document sits at its start, NUL-padded to the device
/// size (see [`crate::config::GuestConfig::from_config_drive`]).
pub fn read_config_drive(device: &str) -> Result<Vec<u8>> {
    let mut f = fs::File::open(device).map_err(|e| format!("open config drive {device}: {e}"))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)
        .map_err(|e| format!("read config drive {device}: {e}"))?;
    Ok(buf)
}

/// Mount the container rootfs onto `NEW_ROOT`.
pub fn mount_container_rootfs(spec: &RootfsSpec) -> Result<()> {
    ensure_dir(NEW_ROOT)?;
    let mut flags = MsFlags::empty();
    if spec.readonly {
        flags |= MsFlags::MS_RDONLY;
    }
    mount(
        Some(spec.device.as_str()),
        NEW_ROOT,
        Some(spec.fstype.as_str()),
        flags,
        NO_DATA,
    )
    .map_err(|e| {
        format!(
            "mount rootfs {} ({}) on {NEW_ROOT}: {e}",
            spec.device, spec.fstype
        )
    })?;
    Ok(())
}

/// Transition from the initramfs onto the container rootfs mounted at
/// `NEW_ROOT`, leaving the process chrooted into it with `/proc`, `/sys` and
/// `/dev` carried across. After this returns the current directory is the new
/// `/`.
pub fn switch_into_rootfs() -> Result<()> {
    // Carry the pseudo-filesystems onto the new root so the workload keeps
    // seeing them. The container image provides the mount points.
    for fs_name in ["dev", "proc", "sys"] {
        let target = format!("{NEW_ROOT}/{fs_name}");
        ensure_dir(&target)?;
        mount(
            Some(format!("/{fs_name}").as_str()),
            target.as_str(),
            NO_FSTYPE,
            MsFlags::MS_MOVE,
            NO_DATA,
        )
        .map_err(|e| format!("move /{fs_name} to {target}: {e}"))?;
    }

    // Move the new root to `/` and chroot into it (switch_root semantics).
    std::env::set_current_dir(NEW_ROOT).map_err(|e| format!("chdir {NEW_ROOT}: {e}"))?;
    mount(Some("."), "/", NO_FSTYPE, MsFlags::MS_MOVE, NO_DATA)
        .map_err(|e| format!("move new root to /: {e}"))?;
    nix::unistd::chroot(".").map_err(|e| format!("chroot: {e}"))?;
    std::env::set_current_dir("/").map_err(|e| format!("chdir / after chroot: {e}"))?;
    Ok(())
}

/// Mount the remaining API filesystems a typical container expects, inside the
/// new root. Best effort: a missing mount point or an already-satisfied mount
/// must not abort the workload launch.
pub fn mount_container_api() -> Result<()> {
    if Path::new("/dev/pts").exists() {
        let _ = mount(
            Some("devpts"),
            "/dev/pts",
            Some("devpts"),
            MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
            Some("gid=5,mode=0620"),
        );
    }
    if Path::new("/dev/shm").exists() {
        let _ = mount(
            Some("shm"),
            "/dev/shm",
            Some("tmpfs"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            Some("mode=1777"),
        );
    }
    // /tmp and /run are commonly writable tmpfs; only mount when the image
    // provides the directory.
    if Path::new("/tmp").exists() {
        let _ = mount(
            Some("tmpfs"),
            "/tmp",
            Some("tmpfs"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            Some("mode=1777"),
        );
    }
    if Path::new("/run").exists() {
        let _ = mount(
            Some("tmpfs"),
            "/run",
            Some("tmpfs"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            Some("mode=0755"),
        );
    }
    Ok(())
}

fn ensure_dir(path: &str) -> Result<()> {
    if !Path::new(path).exists() {
        fs::create_dir_all(path).map_err(|e| format!("mkdir {path}: {e}"))?;
    }
    Ok(())
}

// Typed `None` for `nix::mount`'s generic optional path/data arguments, which
// otherwise cannot infer a concrete `NixPath` type.
const NO_DATA: Option<&str> = None;
const NO_FSTYPE: Option<&str> = None;
