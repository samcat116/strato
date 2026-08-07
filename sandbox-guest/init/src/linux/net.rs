//! In-guest network bring-up (STR-101) — the syscall half.
//!
//! The config drive hands the guest a fully resolved L3 configuration (see
//! [`strato_sandbox_init::config::NetworkConfig`]), so there is no discovery to
//! do here: find the interface the host programmed, put the address on it,
//! point the default route at the gateway, and set the MTU.
//!
//! It is all hand-rolled `ioctl` plus one rtnetlink message per default route
//! rather than a crate. The initramfs is built `opt-level = "z"`, `lto`,
//! `panic = "abort"` and ships in *every* sandbox; a general-purpose netlink
//! library would not pay for itself configuring one interface. The ioctls are
//! the classic `SIOC*` numbers, identical across Linux architectures.
//!
//! Addresses go on with ioctls (`SIOCSIFADDR`/`SIOCSIFNETMASK` for IPv4, the
//! `in6_ifreq` form of `SIOCSIFADDR` for IPv6) because assigning an address is
//! all they do. Routes have no ioctl worth using — `SIOCADDRT` cannot express
//! an IPv6 route the same way — so the default route is one `RTM_NEWROUTE`.

use std::fs;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::Path;

use strato_sandbox_init::config::{AddressConfig, NetworkConfig};
use strato_sandbox_init::net;

type Result<T> = std::result::Result<T, String>;

/// Kernel interface-name buffer size (`IFNAMSIZ`), including the NUL.
const IF_NAMESIZE: usize = 16;

// Socket ioctls. Numbered in the architecture-independent 0x89xx range, so
// these are the same values on x86_64 and aarch64.
const SIOCGIFFLAGS: u32 = 0x8913;
const SIOCSIFFLAGS: u32 = 0x8914;
const SIOCSIFADDR: u32 = 0x8916;
const SIOCSIFNETMASK: u32 = 0x891c;
const SIOCSIFMTU: u32 = 0x8922;
const SIOCGIFINDEX: u32 = 0x8933;

// rtnetlink message pieces (linux/rtnetlink.h, linux/netlink.h).
const RTM_NEWROUTE: u16 = 24;
const NLM_F_REQUEST: u16 = 0x001;
const NLM_F_ACK: u16 = 0x004;
const NLM_F_REPLACE: u16 = 0x100;
const NLM_F_CREATE: u16 = 0x400;
const NLMSG_ERROR: u16 = 2;
const RT_TABLE_MAIN: u8 = 254;
const RTPROT_BOOT: u8 = 3;
const RT_SCOPE_UNIVERSE: u8 = 0;
const RTN_UNICAST: u8 = 1;
const RTA_OIF: u16 = 4;
const RTA_GATEWAY: u16 = 5;

/// Bring the loopback interface up.
///
/// Done for every sandbox, networked or not: plenty of workloads bind or dial
/// `127.0.0.1` with no NIC in sight, and until `lo` is up they cannot. The
/// kernel adds `127.0.0.1/8` and `::1/128` itself once the link comes up, so
/// there is nothing else to assign.
pub fn bring_up_loopback() -> Result<()> {
    let sock = Socket::open(libc::AF_INET)?;
    set_link_up(&sock, "lo")
}

/// Apply the config drive's network block: match the NIC by MAC, set its MTU,
/// bring it up, assign each family's address, and install each family's
/// default route. Returns the interface name it configured.
///
/// Every step is an error rather than a warning. A sandbox whose NIC is half
/// configured looks identical to a healthy one from the host's side — the VMM
/// is running and the guest answers vsock — so failing the boot is what keeps
/// "running" from meaning "running with a dead interface".
pub fn configure_interface(config: &NetworkConfig) -> Result<String> {
    let name = find_interface(config.mac_address.as_deref())?;

    let sock = Socket::open(libc::AF_INET)?;
    if let Some(mtu) = config.mtu {
        set_mtu(&sock, &name, mtu)?;
    }
    // Up before addressing: the kernel drops the connected route for an
    // address assigned to a down link, and IPv6 refuses the assignment
    // outright until the device is up.
    set_link_up(&sock, &name)?;
    let index = interface_index(&sock, &name)?;

    if let Some(v4) = &config.ipv4 {
        let address: Ipv4Addr = parse(&v4.address, "IPv4 address")?;
        if v4.prefix_length > 32 {
            return Err(format!(
                "IPv4 prefix length {} is out of range",
                v4.prefix_length
            ));
        }
        set_ipv4_address(&sock, &name, address, v4.prefix_length)?;
        if let Some(gateway) = gateway_of(v4) {
            let gateway: Ipv4Addr = parse(gateway, "IPv4 gateway")?;
            add_default_route(libc::AF_INET as u8, &gateway.octets(), index)?;
        }
    }

    if let Some(v6) = &config.ipv6 {
        let address: Ipv6Addr = parse(&v6.address, "IPv6 address")?;
        if v6.prefix_length > 128 {
            return Err(format!(
                "IPv6 prefix length {} is out of range",
                v6.prefix_length
            ));
        }
        let sock6 = Socket::open(libc::AF_INET6)?;
        set_ipv6_address(&sock6, index, address, v6.prefix_length)?;
        if let Some(gateway) = gateway_of(v6) {
            let gateway: Ipv6Addr = parse(gateway, "IPv6 gateway")?;
            add_default_route(libc::AF_INET6 as u8, &gateway.octets(), index)?;
        }
    }

    if let Some(hostname) = config.hostname.as_deref() {
        set_hostname(hostname)?;
    }
    Ok(name)
}

/// Write `/etc/resolv.conf` and `/etc/hosts` into the container rootfs mounted
/// at `root`, before the init switches onto it.
///
/// Best effort, unlike the interface itself: a read-only rootfs is a legitimate
/// sandbox shape, and a workload that does its own resolution (or none) should
/// not lose its network because its image would not take a file. Scratch and
/// distroless images may have no `/etc` at all, so the directory is created
/// rather than assumed, and an existing entry is unlinked first — images ship
/// `resolv.conf` as a symlink into `/run` often enough that writing through one
/// would land the file somewhere a tmpfs mount then hides.
pub fn write_resolver_files(root: &Path, config: &NetworkConfig) {
    let etc = root.join("etc");
    if let Err(e) = fs::create_dir_all(&etc) {
        eprintln!("[sandbox-init] could not create {}: {e}", etc.display());
        return;
    }
    if let Some(resolv) = net::resolv_conf(config) {
        replace_file(&join_absolute(root, net::RESOLV_CONF_PATH), &resolv);
    }
    replace_file(
        &join_absolute(root, net::HOSTS_PATH),
        &net::hosts_file(config),
    );
}

/// Set the guest's hostname. Shared with the fork re-identification path
/// (issue #426), which renames a restored guest over vsock.
pub fn set_hostname(hostname: &str) -> Result<()> {
    net::validate_hostname(hostname)?;
    let rc = unsafe { libc::sethostname(hostname.as_ptr().cast(), hostname.len()) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
    }
}

/// Resolve the interface to configure: the one whose MAC matches, or — when
/// the host named no MAC — the sole non-loopback interface.
///
/// A named MAC that matches nothing is an error rather than a fallback. The
/// MAC is also what OVN's `port_security` allows on the wire, so configuring
/// some other device would produce an interface that is up, addressed, and
/// silently dropped upstream.
fn find_interface(mac_address: Option<&str>) -> Result<String> {
    let wanted = mac_address
        .map(|m| m.trim().to_ascii_lowercase())
        .filter(|m| !m.is_empty());

    let mut candidates: Vec<String> = Vec::new();
    let entries =
        fs::read_dir("/sys/class/net").map_err(|e| format!("list /sys/class/net: {e}"))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("read /sys/class/net: {e}"))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "lo" {
            continue;
        }
        if let Some(wanted) = &wanted {
            let path = format!("/sys/class/net/{name}/address");
            let found = fs::read_to_string(&path).unwrap_or_default();
            if found.trim().to_ascii_lowercase() == *wanted {
                return Ok(name);
            }
        }
        candidates.push(name);
    }
    candidates.sort();

    match wanted {
        Some(wanted) => Err(format!(
            "no interface with MAC {wanted} (found: {})",
            describe(&candidates)
        )),
        None if candidates.len() == 1 => Ok(candidates.remove(0)),
        None => Err(format!(
            "the config drive named no MAC and there is no single non-loopback interface (found: {})",
            describe(&candidates)
        )),
    }
}

fn describe(candidates: &[String]) -> String {
    if candidates.is_empty() {
        "none".to_string()
    } else {
        candidates.join(", ")
    }
}

fn set_link_up(sock: &Socket, name: &str) -> Result<()> {
    let mut req = IfReq::new(name)?;
    sock.ioctl(SIOCGIFFLAGS, &mut req, "SIOCGIFFLAGS", name)?;
    // `ifr_flags` is a short at the head of the union.
    let mut flags = u16::from_ne_bytes([req.data[0], req.data[1]]);
    flags |= libc::IFF_UP as u16;
    req.data[..2].copy_from_slice(&flags.to_ne_bytes());
    sock.ioctl(SIOCSIFFLAGS, &mut req, "SIOCSIFFLAGS", name)
}

fn set_mtu(sock: &Socket, name: &str, mtu: u32) -> Result<()> {
    let mut req = IfReq::new(name)?;
    req.data[..4].copy_from_slice(&(mtu as i32).to_ne_bytes());
    sock.ioctl(SIOCSIFMTU, &mut req, "SIOCSIFMTU", name)
}

fn interface_index(sock: &Socket, name: &str) -> Result<u32> {
    let mut req = IfReq::new(name)?;
    sock.ioctl(SIOCGIFINDEX, &mut req, "SIOCGIFINDEX", name)?;
    let index = i32::from_ne_bytes([req.data[0], req.data[1], req.data[2], req.data[3]]);
    u32::try_from(index).map_err(|_| format!("interface {name} reported index {index}"))
}

fn set_ipv4_address(sock: &Socket, name: &str, address: Ipv4Addr, prefix: u8) -> Result<()> {
    let mut req = IfReq::new(name)?;
    req.data[..16].copy_from_slice(&sockaddr_in(address));
    sock.ioctl(SIOCSIFADDR, &mut req, "SIOCSIFADDR", name)?;

    // The address ioctl leaves a classful mask behind, and the mask is what
    // decides the on-link route the kernel derives — so it is set second, not
    // optionally.
    let mask = if prefix == 0 {
        Ipv4Addr::UNSPECIFIED
    } else {
        Ipv4Addr::from(u32::MAX << (32 - u32::from(prefix)))
    };
    let mut req = IfReq::new(name)?;
    req.data[..16].copy_from_slice(&sockaddr_in(mask));
    sock.ioctl(SIOCSIFNETMASK, &mut req, "SIOCSIFNETMASK", name)
}

fn set_ipv6_address(sock6: &Socket, index: u32, address: Ipv6Addr, prefix: u8) -> Result<()> {
    // `struct in6_ifreq` — the IPv6 form of SIOCSIFADDR, which takes an
    // interface index rather than a name.
    #[repr(C)]
    struct In6IfReq {
        addr: [u8; 16],
        prefix_length: u32,
        index: i32,
    }
    let mut req = In6IfReq {
        addr: address.octets(),
        prefix_length: u32::from(prefix),
        index: index as i32,
    };
    let rc = unsafe { libc::ioctl(sock6.fd, SIOCSIFADDR as _, &mut req as *mut In6IfReq) };
    if rc == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    // The IPv4 ioctl *replaces* the primary address, so re-running is a no-op;
    // its IPv6 counterpart *adds* one and answers EEXIST when this exact
    // address is already on the device. Same end state either way, so treat it
    // as success and keep the whole function safe to re-run.
    if error.raw_os_error() == Some(libc::EEXIST) {
        return Ok(());
    }
    Err(format!(
        "SIOCSIFADDR (IPv6) on interface index {index}: {error}"
    ))
}

/// This family's gateway, if the config names a non-blank one.
fn gateway_of(config: &AddressConfig) -> Option<&str> {
    config
        .gateway
        .as_deref()
        .map(str::trim)
        .filter(|g| !g.is_empty())
}

/// Send one `RTM_NEWROUTE` installing `0.0.0.0/0` (or `::/0`) via `gateway` on
/// `index`, and wait for the kernel's ACK.
///
/// `NLM_F_CREATE | NLM_F_REPLACE` rather than plain create so a retry — a
/// second boot of a restored guest, say — overwrites instead of failing
/// `EEXIST`.
fn add_default_route(family: u8, gateway: &[u8], index: u32) -> Result<()> {
    let sock = netlink_socket()?;

    // nlmsghdr(16) + rtmsg(12) + RTA_GATEWAY + RTA_OIF, each attribute
    // 4-byte aligned (every piece here is already a multiple of 4).
    let mut message: Vec<u8> = Vec::with_capacity(64);
    message.extend_from_slice(&0u32.to_ne_bytes()); // nlmsg_len, patched below
    message.extend_from_slice(&RTM_NEWROUTE.to_ne_bytes());
    message.extend_from_slice(
        &(NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE).to_ne_bytes(),
    );
    message.extend_from_slice(&1u32.to_ne_bytes()); // nlmsg_seq
    message.extend_from_slice(&0u32.to_ne_bytes()); // nlmsg_pid (kernel fills in)

    message.push(family); // rtm_family
    message.push(0); // rtm_dst_len — 0 is the default route
    message.push(0); // rtm_src_len
    message.push(0); // rtm_tos
    message.push(RT_TABLE_MAIN);
    message.push(RTPROT_BOOT);
    message.push(RT_SCOPE_UNIVERSE);
    message.push(RTN_UNICAST);
    message.extend_from_slice(&0u32.to_ne_bytes()); // rtm_flags

    push_attribute(&mut message, RTA_GATEWAY, gateway);
    push_attribute(&mut message, RTA_OIF, &index.to_ne_bytes());

    let length = message.len() as u32;
    message[..4].copy_from_slice(&length.to_ne_bytes());

    sock.send_to_kernel(&message)?;
    sock.await_ack()
}

fn push_attribute(message: &mut Vec<u8>, kind: u16, payload: &[u8]) {
    let length = (4 + payload.len()) as u16;
    message.extend_from_slice(&length.to_ne_bytes());
    message.extend_from_slice(&kind.to_ne_bytes());
    message.extend_from_slice(payload);
    // rtnetlink attributes are 4-byte aligned.
    let padding = (4 - (payload.len() % 4)) % 4;
    message.extend(std::iter::repeat(0u8).take(padding));
}

fn netlink_socket() -> Result<Socket> {
    let fd = unsafe {
        libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_RAW | libc::SOCK_CLOEXEC,
            libc::NETLINK_ROUTE,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open rtnetlink socket: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(Socket { fd })
}

fn sockaddr_in(address: Ipv4Addr) -> [u8; 16] {
    let mut out = [0u8; 16];
    // sin_family, then (skipping a zero sin_port) sin_addr, which wants
    // network order — exactly what `octets()` already is.
    out[..2].copy_from_slice(&(libc::AF_INET as u16).to_ne_bytes());
    out[4..8].copy_from_slice(&address.octets());
    out
}

fn parse<A: std::str::FromStr>(value: &str, what: &str) -> Result<A> {
    value
        .trim()
        .parse()
        .map_err(|_| format!("cannot parse {what} '{value}'"))
}

/// Join an absolute in-guest path (`/etc/hosts`) under the not-yet-switched
/// root. `Path::join` would discard `root` for an absolute argument.
fn join_absolute(root: &Path, absolute: &str) -> std::path::PathBuf {
    root.join(absolute.trim_start_matches('/'))
}

fn replace_file(path: &Path, contents: &str) {
    // Unlink first: the image may ship this path as a symlink, and writing
    // through it would put the file wherever it points.
    let _ = fs::remove_file(path);
    if let Err(e) = fs::write(path, contents) {
        eprintln!("[sandbox-init] could not write {}: {e}", path.display());
    }
}

/// A `struct ifreq`: the name plus the kernel's `ifr_ifru` union, whose
/// largest member (`struct ifmap`) fits in 24 bytes on the 64-bit targets the
/// guest is built for.
#[repr(C)]
struct IfReq {
    name: [libc::c_char; IF_NAMESIZE],
    data: [u8; 24],
}

impl IfReq {
    fn new(name: &str) -> Result<IfReq> {
        let bytes = name.as_bytes();
        if bytes.is_empty() || bytes.len() >= IF_NAMESIZE {
            return Err(format!("interface name '{name}' does not fit IFNAMSIZ"));
        }
        let mut req = IfReq {
            name: [0; IF_NAMESIZE],
            data: [0; 24],
        };
        for (slot, byte) in req.name.iter_mut().zip(bytes) {
            *slot = *byte as libc::c_char;
        }
        Ok(req)
    }
}

/// An owned socket file descriptor, closed on drop.
struct Socket {
    fd: libc::c_int,
}

impl Socket {
    fn open(domain: libc::c_int) -> Result<Socket> {
        let fd = unsafe { libc::socket(domain, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return Err(format!(
                "open configuration socket: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(Socket { fd })
    }

    fn ioctl(&self, request: u32, req: &mut IfReq, what: &str, name: &str) -> Result<()> {
        let rc = unsafe { libc::ioctl(self.fd, request as _, req as *mut IfReq) };
        if rc == 0 {
            Ok(())
        } else {
            Err(format!(
                "{what} on {name}: {}",
                std::io::Error::last_os_error()
            ))
        }
    }

    fn send_to_kernel(&self, message: &[u8]) -> Result<()> {
        // `struct sockaddr_nl` addressed to the kernel (pid 0, no groups).
        #[repr(C)]
        struct SockaddrNl {
            family: u16,
            pad: u16,
            pid: u32,
            groups: u32,
        }
        let destination = SockaddrNl {
            family: libc::AF_NETLINK as u16,
            pad: 0,
            pid: 0,
            groups: 0,
        };
        let sent = unsafe {
            libc::sendto(
                self.fd,
                message.as_ptr().cast(),
                message.len(),
                0,
                (&destination as *const SockaddrNl).cast(),
                std::mem::size_of::<SockaddrNl>() as libc::socklen_t,
            )
        };
        if sent < 0 {
            return Err(format!(
                "send rtnetlink request: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }

    /// Read the kernel's reply to an `NLM_F_ACK` request. Success is an
    /// `NLMSG_ERROR` message carrying error 0 — netlink's ACK *is* an error
    /// message with no error in it.
    fn await_ack(&self) -> Result<()> {
        let mut buffer = [0u8; 4096];
        let read = unsafe { libc::recv(self.fd, buffer.as_mut_ptr().cast(), buffer.len(), 0) };
        if read < 0 {
            return Err(format!(
                "read rtnetlink reply: {}",
                std::io::Error::last_os_error()
            ));
        }
        let read = read as usize;
        if read < 20 {
            return Err(format!("truncated rtnetlink reply ({read} bytes)"));
        }
        let kind = u16::from_ne_bytes([buffer[4], buffer[5]]);
        if kind != NLMSG_ERROR {
            return Err(format!("unexpected rtnetlink reply type {kind}"));
        }
        let code = i32::from_ne_bytes([buffer[16], buffer[17], buffer[18], buffer[19]]);
        if code == 0 {
            Ok(())
        } else {
            Err(format!(
                "rtnetlink rejected the route: {}",
                std::io::Error::from_raw_os_error(-code)
            ))
        }
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn netmask_is_derived_from_the_prefix() {
        // The dotted mask never travels on the config drive (IPv6 has no such
        // form), so the guest is where the prefix becomes one.
        let mask = |prefix: u8| {
            let mut req = IfReq::new("eth0").expect("ifreq");
            let value = if prefix == 0 {
                Ipv4Addr::UNSPECIFIED
            } else {
                Ipv4Addr::from(u32::MAX << (32 - u32::from(prefix)))
            };
            req.data[..16].copy_from_slice(&sockaddr_in(value));
            Ipv4Addr::new(req.data[4], req.data[5], req.data[6], req.data[7])
        };
        assert_eq!(mask(24), Ipv4Addr::new(255, 255, 255, 0));
        assert_eq!(mask(16), Ipv4Addr::new(255, 255, 0, 0));
        assert_eq!(mask(32), Ipv4Addr::new(255, 255, 255, 255));
        assert_eq!(mask(0), Ipv4Addr::UNSPECIFIED);
    }

    #[test]
    fn sockaddr_in_is_family_then_network_order_address() {
        let bytes = sockaddr_in(Ipv4Addr::new(172, 16, 0, 5));
        assert_eq!(
            u16::from_ne_bytes([bytes[0], bytes[1]]),
            libc::AF_INET as u16
        );
        assert_eq!(&bytes[4..8], &[172, 16, 0, 5]);
    }

    #[test]
    fn attributes_are_padded_to_four_bytes() {
        let mut message = Vec::new();
        push_attribute(&mut message, RTA_GATEWAY, &[10, 0, 0, 1]);
        assert_eq!(message.len(), 8, "a 4-byte payload needs no padding");
        assert_eq!(u16::from_ne_bytes([message[0], message[1]]), 8);

        let mut message = Vec::new();
        push_attribute(&mut message, RTA_GATEWAY, &[0xfd; 16]);
        assert_eq!(message.len(), 20);
        assert_eq!(
            u16::from_ne_bytes([message[0], message[1]]),
            20,
            "the header length excludes padding, of which there is none here"
        );

        // An odd payload is padded out, but the declared length is not.
        let mut message = Vec::new();
        push_attribute(&mut message, RTA_OIF, &[1, 2, 3]);
        assert_eq!(u16::from_ne_bytes([message[0], message[1]]), 7);
        assert_eq!(message.len(), 8);
    }

    #[test]
    fn ifreq_rejects_a_name_that_does_not_fit() {
        assert!(IfReq::new("").is_err());
        assert!(
            IfReq::new("0123456789abcdef").is_err(),
            "16 bytes leaves no NUL"
        );
        assert!(IfReq::new("0123456789abcde").is_ok());
    }

    #[test]
    fn absolute_guest_paths_land_under_the_new_root() {
        assert_eq!(
            join_absolute(Path::new("/newroot"), "/etc/hosts"),
            Path::new("/newroot/etc/hosts")
        );
    }
}
