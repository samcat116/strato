//! Strato sandbox guest init / guest-agent (issue #419).
//!
//! The binary (`src/main.rs`) is a Linux-only PID-1 init that boots inside a
//! Firecracker microVM. This library holds the parts that carry no Linux
//! syscall dependency — the config-drive format, the OCI process-config merge,
//! and the vsock control protocol — so they can be unit-tested on any host.
//!
//! Boot contract (produced host-side by the sandbox runtime, issue #421):
//!   * kernel + initramfs (this init) via Firecracker `boot-source`;
//!   * `/dev/vda` — the flattened container rootfs (issue #418), left pristine;
//!   * `/dev/vdb` — a read-only config drive carrying [`config::GuestConfig`];
//!   * a vsock device the host connects to for [`protocol`] control ops,
//!     exec sessions, and workload-log follow streams (backed by [`logbuf`]).

pub mod config;
pub mod logbuf;
pub mod protocol;
