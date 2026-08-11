//! Portable guest-side code shared by Strato's sandbox init and VM guest agent.
//!
//! The binary (`src/main.rs`) is a Linux-only PID-1 init that boots inside a
//! Firecracker microVM. `strato-guest-agent` is a normal Linux service for
//! general-purpose VMs. This library holds the parts that carry no Linux syscall
//! dependency — most importantly the shared vsock control protocol — so both
//! speakers use one wire definition and its tests run on any host.
//!
//! Boot contract (produced host-side by the sandbox runtime, issue #421):
//!   * kernel + initramfs (this init) via Firecracker `boot-source`;
//!   * `/dev/vda` — the flattened container rootfs (issue #418), left pristine;
//!   * `/dev/vdb` — a read-only config drive carrying [`config::GuestConfig`];
//!   * a vsock device the host connects to for [`protocol`] control ops,
//!     exec sessions, and workload-log follow streams (backed by [`logbuf`]);
//!   * optionally one virtio-net NIC, configured statically from the config
//!     drive's network block (see [`net`] and `linux::net`).

pub mod config;
pub mod identity;
pub mod logbuf;
pub mod net;
pub mod protocol;
