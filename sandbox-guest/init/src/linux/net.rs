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

/// How many times, and how far apart, to scan `/sys/class/net` for the NIC
/// before declaring it absent. Half a second total: enough to cover a slower
/// device probe, short enough not to matter to a cold start that is otherwise
/// measured in tens of milliseconds.
const INTERFACE_SCAN_ATTEMPTS: u32 = 10;
const INTERFACE_SCAN_INTERVAL: std::time::Duration = std::time::Duration::from_millis(50);

// Socket ioctls. Numbered in the architecture-independent 0x89xx range, so
// these are the same values on x86_64 and aarch64.
const SIOCGIFFLAGS: u32 = 0x8913;
const SIOCSIFFLAGS: u32 = 0x8914;
const SIOCSIFADDR: u32 = 0x8916;
const SIOCDIFADDR: u32 = 0x8936;
const SIOCSIFNETMASK: u32 = 0x891c;
const SIOCSIFHWADDR: u32 = 0x8924;
const SIOCSIFMTU: u32 = 0x8922;
const SIOCGIFINDEX: u32 = 0x8933;

/// `ARPHRD_ETHER`, the hardware type `SIOCSIFHWADDR` wants in the
/// `sockaddr`'s family field.
const ARPHRD_ETHER: u16 = 1;

/// Where the kernel lists every IPv6 address on the system, one per line:
/// `<32 hex chars> <ifindex> <prefix> <scope> <flags> <devname>`.
const PROC_NET_IF_INET6: &str = "/proc/net/if_inet6";

/// `IPV6_ADDR_SCOPE_LINKLOCAL` as reported in `/proc/net/if_inet6`'s scope
/// column. Link-local addresses are the kernel's, not ours, so a flush leaves
/// them alone.
const IPV6_SCOPE_LINKLOCAL: u32 = 0x20;

// rtnetlink message pieces (linux/rtnetlink.h, linux/netlink.h).
const RTM_NEWROUTE: u16 = 24;
const RTM_DELROUTE: u16 = 25;
const NLM_F_REQUEST: u16 = 0x001;
const NLM_F_ACK: u16 = 0x004;
const NLM_F_REPLACE: u16 = 0x100;
const NLM_F_CREATE: u16 = 0x400;
const NLMSG_ERROR: u16 = 2;
const RT_TABLE_MAIN: u8 = 254;
const RTPROT_UNSPEC: u8 = 0;
const RTPROT_BOOT: u8 = 3;
const RT_SCOPE_UNIVERSE: u8 = 0;
const RT_SCOPE_NOWHERE: u8 = 255;
const RTN_UNSPEC: u8 = 0;
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
/// The hostname is deliberately *not* set here — it belongs to the sandbox,
/// not to its NIC, so the caller applies it for networked and network-free
/// sandboxes alike.
///
/// Every step is an error rather than a warning. A sandbox whose NIC is half
/// configured looks identical to a healthy one from the host's side — the VMM
/// is running and the guest answers vsock — so failing the boot is what keeps
/// "running" from meaning "running with a dead interface".
pub fn configure_interface(config: &NetworkConfig) -> Result<String> {
    let name = find_interface(config.mac_address.as_deref())?;
    apply_configuration(&name, config)?;
    Ok(name)
}

/// Re-address the NIC of a guest that was restored from someone else's
/// checkpoint (STR-104): a warm template shared across sandboxes, or a fork of
/// another sandbox's snapshot.
///
/// The host has already repointed the virtio device at this sandbox's TAP
/// (`network_overrides` on snapshot load), but everything above the device is
/// still whatever the checkpointed kernel had: the source's MAC baked into the
/// virtio config, its address, its routes. Leaving any of it would put a
/// sandbox on the network under an identity OVN's `port_security` does not
/// allow and — for a fork — that still belongs to a live sandbox.
///
/// `previous` is the configuration this guest last applied, if any; it is only
/// a hint for finding the device.
///
/// Idempotent, because the host retries: re-running with the same config finds
/// the interface by its already-applied MAC and lands in the same state.
pub fn reconfigure_interface(
    previous: Option<&NetworkConfig>,
    config: &NetworkConfig,
) -> Result<String> {
    let name = find_interface_for_reconfigure(
        config.mac_address.as_deref(),
        previous.and_then(|p| p.mac_address.as_deref()),
    )?;

    let sock = Socket::open(libc::AF_INET)?;
    // Addresses first, while the device is still up: removing them is what
    // takes the routes that depend on them with it, so nothing survives into
    // the new configuration by having been unreachable at flush time.
    flush_addresses(&sock, &name)?;
    // A MAC change needs the device down — the kernel refuses `SIOCSIFHWADDR`
    // on a running one — and this is the step that actually matters upstream:
    // the frames the guest transmits are what OVN filters on.
    set_link_down(&sock, &name)?;
    if let Some(mac) = config.mac_address.as_deref() {
        set_mac_address(&sock, &name, mac)?;
    }

    apply_configuration(&name, config)?;

    // Whatever default route the checkpoint carried for a family this config
    // has no gateway for. Flushing the addresses above normally removes it
    // already (the kernel drops routes whose gateway stops being on-link), so
    // this is the belt to that braces and its failure is not the sandbox's
    // problem.
    let index = interface_index(&sock, &name)?;
    for (family, label, present) in [
        (libc::AF_INET as u8, "IPv4", config.ipv4.as_ref()),
        (libc::AF_INET6 as u8, "IPv6", config.ipv6.as_ref()),
    ] {
        if present.and_then(gateway_of).is_none() {
            if let Err(e) = delete_default_route(family, index) {
                eprintln!("[sandbox-init] stale {label} default route on {name}: {e}");
            }
        }
    }

    Ok(name)
}

/// MTU, link up, addresses and default routes for an interface already
/// resolved by name. Shared by the cold-boot path and the restore-time
/// reconfiguration so the two can never drift.
fn apply_configuration(name: &str, config: &NetworkConfig) -> Result<()> {
    let sock = Socket::open(libc::AF_INET)?;
    if let Some(mtu) = config.mtu {
        set_mtu(&sock, name, mtu)?;
    }
    // Up before addressing: the kernel drops the connected route for an
    // address assigned to a down link, and IPv6 refuses the assignment
    // outright until the device is up.
    set_link_up(&sock, name)?;
    let index = interface_index(&sock, name)?;

    if let Some(v4) = &config.ipv4 {
        let address: Ipv4Addr = parse(&v4.address, "IPv4 address")?;
        if v4.prefix_length > 32 {
            return Err(format!(
                "IPv4 prefix length {} is out of range",
                v4.prefix_length
            ));
        }
        set_ipv4_address(&sock, name, address, v4.prefix_length)?;
        if let Some(gateway) = gateway_of(v4) {
            let parsed: Ipv4Addr = parse(gateway, "IPv4 gateway")?;
            add_default_route(
                libc::AF_INET as u8,
                &parsed.octets(),
                index,
                "IPv4",
                gateway,
            )?;
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
            let parsed: Ipv6Addr = parse(gateway, "IPv6 gateway")?;
            add_default_route(
                libc::AF_INET6 as u8,
                &parsed.octets(),
                index,
                "IPv6",
                gateway,
            )?;
        }
    }

    Ok(())
}

/// Write `/etc/resolv.conf` and `/etc/hosts` into the container rootfs mounted
/// at `root`, before the init switches onto it.
///
/// Called for every sandbox, not only networked ones: `/etc/hosts` is what
/// makes `localhost` resolve, and a scratch or distroless image may ship no
/// `/etc` at all — which is just as true of a sandbox with no NIC, now that it
/// gets a working `lo`. `resolv.conf` is skipped when there are no resolvers
/// to name, so the network-free case writes only the loopback host table.
///
/// Best effort, unlike the interface itself: a read-only rootfs is a legitimate
/// sandbox shape, and a workload that does its own resolution (or none) should
/// not lose its network because its image would not take a file. An existing
/// entry is unlinked first — images ship `resolv.conf` as a symlink into `/run`
/// often enough that writing through one would land the file somewhere a tmpfs
/// mount then hides.
pub fn write_resolver_files(root: &Path, hostname: Option<&str>, config: Option<&NetworkConfig>) {
    let etc = root.join("etc");
    if let Err(e) = fs::create_dir_all(&etc) {
        eprintln!("[sandbox-init] could not create {}: {e}", etc.display());
        return;
    }
    if let Some(resolv) = config.and_then(net::resolv_conf) {
        replace_file(&join_absolute(root, net::RESOLV_CONF_PATH), &resolv);
    }
    replace_file(
        &join_absolute(root, net::HOSTS_PATH),
        &net::hosts_file(hostname, config),
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
/// Failing here is fatal, and "not found" is indistinguishable from "not
/// yet" — so the scan is retried briefly before it gives up. With virtio-net
/// built in (these kernel fragments enable no modules) the device is probed
/// before PID 1 runs and the first attempt always wins; the retry costs
/// nothing in that case and covers a slower probe rather than assuming one
/// cannot happen.
fn find_interface(mac_address: Option<&str>) -> Result<String> {
    let mut last = Err(String::new());
    for attempt in 0..INTERFACE_SCAN_ATTEMPTS {
        last = scan_for_interface(mac_address);
        if last.is_ok() {
            return last;
        }
        if attempt + 1 < INTERFACE_SCAN_ATTEMPTS {
            std::thread::sleep(INTERFACE_SCAN_INTERVAL);
        }
    }
    last
}

fn scan_for_interface(mac_address: Option<&str>) -> Result<String> {
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

/// Resolve the device to re-address on a restored guest.
///
/// Three probes, in decreasing order of confidence. The **new** MAC first, so a
/// retried request (the host retries a failed launch or re-identification)
/// finds the device it already renamed. Then the MAC this guest last applied,
/// which is what the device still carries on the first attempt. Then, only if
/// neither matched, the sole non-loopback interface — safe here in a way it is
/// not on the cold path, because there is exactly one of them and the
/// alternative is refusing to re-address a device whose MAC the checkpoint set
/// before this init ever ran.
fn find_interface_for_reconfigure(wanted: Option<&str>, previous: Option<&str>) -> Result<String> {
    let mut last = Err("no interface probe ran".to_string());
    for mac in [wanted, previous] {
        let Some(mac) = mac else { continue };
        last = scan_for_interface(Some(mac));
        if last.is_ok() {
            return last;
        }
    }
    scan_for_interface(None).or(last)
}

fn describe(candidates: &[String]) -> String {
    if candidates.is_empty() {
        "none".to_string()
    } else {
        candidates.join(", ")
    }
}

/// Set the device's hardware address. The device must be down.
///
/// virtio-net has no control virtqueue in Firecracker, so the driver writes the
/// address into the device's config space and the kernel adopts it locally —
/// which is all that matters, since the host TAP forwards whatever the guest
/// transmits and OVN filters on the source MAC of the frame.
fn set_mac_address(sock: &Socket, name: &str, mac: &str) -> Result<()> {
    let bytes = parse_mac(mac)?;
    let mut req = IfReq::new(name)?;
    // `struct sockaddr`: family, then 14 bytes of `sa_data` holding the address.
    req.data[..2].copy_from_slice(&ARPHRD_ETHER.to_ne_bytes());
    req.data[2..8].copy_from_slice(&bytes);
    sock.ioctl(SIOCSIFHWADDR, &mut req, "SIOCSIFHWADDR", name)
}

fn parse_mac(mac: &str) -> Result<[u8; 6]> {
    let mut out = [0u8; 6];
    let mut parts = mac.trim().split(':');
    for slot in out.iter_mut() {
        let part = parts.next().ok_or_else(|| format!("bad MAC '{mac}'"))?;
        *slot = u8::from_str_radix(part, 16).map_err(|_| format!("bad MAC '{mac}'"))?;
    }
    if parts.next().is_some() {
        return Err(format!("bad MAC '{mac}'"));
    }
    Ok(out)
}

/// Clear the device's addresses, which the two families do to different
/// depths — worth knowing exactly, because this is what a fork's identity
/// boundary actually amounts to at L3.
///
/// **IPv6 is complete**: every non-link-local address on the device is
/// enumerated and deleted, whoever added it. Link-local is deliberately left —
/// the kernel owns it and re-derives one from the new MAC.
///
/// **IPv4 is the primary address only.** `SIOCSIFADDR` with `0.0.0.0` is the
/// classic "unset the address" call and it is all the ioctl API can see;
/// a *secondary* address (`ip addr add`, netlink) survives it. That is moot on
/// the warm-launch path, where no workload has run — but a fork restores a
/// live sandbox, so a workload that added its own IPv4 address carries it into
/// the fork. Nothing escapes: OVN `port_security` on the fork's port drops
/// frames whose source does not match the fork's own allocation. What is wrong
/// is only the guest's own view of itself, and closing that would mean an
/// `RTM_GETADDR` dump here — worth doing if it ever matters, and deliberately
/// not done blind.
fn flush_addresses(sock: &Socket, name: &str) -> Result<()> {
    let mut req = IfReq::new(name)?;
    req.data[..16].copy_from_slice(&sockaddr_in(Ipv4Addr::UNSPECIFIED));
    sock.ioctl(SIOCSIFADDR, &mut req, "SIOCSIFADDR (flush)", name)?;

    let sock6 = Socket::open(libc::AF_INET6)?;
    let index = interface_index(sock, name)?;
    for address in global_ipv6_addresses(name) {
        delete_ipv6_address(&sock6, index, address)?;
    }
    Ok(())
}

/// The non-link-local IPv6 addresses currently on `name`, read from
/// `/proc/net/if_inet6` (there is no ioctl that enumerates them).
///
/// An unreadable file yields nothing rather than an error: the caller is about
/// to assign the address it wants either way, and a stale leftover is a smaller
/// problem than refusing to configure the NIC at all.
fn global_ipv6_addresses(name: &str) -> Vec<Ipv6Addr> {
    fs::read_to_string(PROC_NET_IF_INET6)
        .map(|contents| parse_if_inet6(&contents, name))
        .unwrap_or_default()
}

/// Parse `/proc/net/if_inet6` for the non-link-local addresses on `name`.
///
/// Each line is `<32 hex chars> <ifindex> <prefix> <scope> <flags> <devname>`,
/// all hex, no header. Split out from the read so the column indices and the
/// scope filter are testable: every failure mode here is a *silent* skip, so a
/// wrong index would not error — it would quietly leave the source sandbox's
/// address on a fork's interface, which is the leak `reidentify` exists to
/// close.
fn parse_if_inet6(contents: &str, name: &str) -> Vec<Ipv6Addr> {
    let mut out = Vec::new();
    for line in contents.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        // hex address, ifindex, prefix, scope, flags, device
        if fields.len() < 6 || fields[5] != name {
            continue;
        }
        let Ok(scope) = u32::from_str_radix(fields[3], 16) else {
            continue;
        };
        // Link-local is the kernel's, and it re-derives one from the new MAC.
        if scope == IPV6_SCOPE_LINKLOCAL {
            continue;
        }
        if fields[0].len() != 32 {
            continue;
        }
        let mut octets = [0u8; 16];
        let mut ok = true;
        for (i, slot) in octets.iter_mut().enumerate() {
            match u8::from_str_radix(&fields[0][i * 2..i * 2 + 2], 16) {
                Ok(byte) => *slot = byte,
                Err(_) => {
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            out.push(Ipv6Addr::from(octets));
        }
    }
    out
}

fn delete_ipv6_address(sock6: &Socket, index: u32, address: Ipv6Addr) -> Result<()> {
    #[repr(C)]
    struct In6IfReq {
        addr: [u8; 16],
        prefix_length: u32,
        index: i32,
    }
    let mut req = In6IfReq {
        addr: address.octets(),
        // The kernel matches the deletion on the address alone; the prefix is
        // carried because the struct has the field.
        prefix_length: 128,
        index: index as i32,
    };
    let rc = unsafe { libc::ioctl(sock6.fd, SIOCDIFADDR as _, &mut req as *mut In6IfReq) };
    if rc == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    // Already gone (the link going down flushed it, or a concurrent retry beat
    // us to it) is the state we asked for.
    if matches!(
        error.raw_os_error(),
        Some(libc::EADDRNOTAVAIL) | Some(libc::ENXIO)
    ) {
        return Ok(());
    }
    Err(format!(
        "SIOCDIFADDR (IPv6) for {address} on interface index {index}: {error}"
    ))
}

fn set_link_up(sock: &Socket, name: &str) -> Result<()> {
    set_link_flag_up(sock, name, true)
}

fn set_link_down(sock: &Socket, name: &str) -> Result<()> {
    set_link_flag_up(sock, name, false)
}

fn set_link_flag_up(sock: &Socket, name: &str, up: bool) -> Result<()> {
    let mut req = IfReq::new(name)?;
    sock.ioctl(SIOCGIFFLAGS, &mut req, "SIOCGIFFLAGS", name)?;
    // `ifr_flags` is a short at the head of the union.
    let mut flags = u16::from_ne_bytes([req.data[0], req.data[1]]);
    if up {
        flags |= libc::IFF_UP as u16;
    } else {
        flags &= !(libc::IFF_UP as u16);
    }
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
///
/// `label` and `gateway_text` exist only for the error message. This call is
/// made once per family and its failure is fatal, so the serial console is the
/// only diagnostic the operator gets — "the route was rejected" without saying
/// *which* route sends them reading the config drive to find out. A gateway
/// outside the on-link prefix is `ENETUNREACH` here for exactly one family.
fn add_default_route(
    family: u8,
    gateway: &[u8],
    index: u32,
    label: &str,
    gateway_text: &str,
) -> Result<()> {
    default_route_request(
        RTM_NEWROUTE,
        NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE,
        family,
        Some(gateway),
        index,
    )
    .map_err(|e| {
        format!(
            "install the {label} default route via {gateway_text} on interface index {index}: {e}"
        )
    })
}

/// Remove whatever default route this device still carries for `family`.
///
/// Used only when re-addressing a restored guest onto a network with no
/// gateway for a family the checkpoint had one for. "Already gone" is the state
/// we want, so the kernel's `ESRCH`/`ENOENT` are success.
fn delete_default_route(family: u8, index: u32) -> Result<()> {
    match default_route_request(RTM_DELROUTE, NLM_F_REQUEST | NLM_F_ACK, family, None, index) {
        Ok(()) => Ok(()),
        Err(e) if tolerated_route_delete_errno(e.errno) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// `ESRCH`/`ENOENT` from a route delete mean the route is not there, which is
/// what the delete was for.
///
/// Matched on the errno the kernel actually sent, not on its `strerror`
/// rendering: this decision makes a benign result fatal if it goes the wrong
/// way — the whole `reconfigure_interface` fails, which fails the
/// `launch`/`reidentify` — and a locale or a libc wording change has no
/// business being what decides it.
fn tolerated_route_delete_errno(errno: Option<i32>) -> bool {
    matches!(errno, Some(libc::ESRCH) | Some(libc::ENOENT))
}

/// A failed rtnetlink exchange, carrying the kernel's errno when it sent one.
///
/// The errno is the authoritative value and callers that treat some failures
/// as success need it; the message is for humans and keeps the surrounding
/// error strings reading the way they did.
#[derive(Debug)]
struct NetlinkFailure {
    /// `-errno` from an `NLMSG_ERROR` reply. None for transport and framing
    /// failures, which have no kernel verdict to report.
    errno: Option<i32>,
    message: String,
}

impl NetlinkFailure {
    fn kernel(errno: i32) -> Self {
        NetlinkFailure {
            errno: Some(errno),
            message: format!(
                "the kernel rejected it: {}",
                std::io::Error::from_raw_os_error(errno)
            ),
        }
    }

    fn transport(message: String) -> Self {
        NetlinkFailure {
            errno: None,
            message,
        }
    }
}

impl std::fmt::Display for NetlinkFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// `(rtm_protocol, rtm_scope, rtm_type)` for a route message of `kind`.
fn route_classification(kind: u16) -> (u8, u8, u8) {
    if kind == RTM_DELROUTE {
        (RTPROT_UNSPEC, RT_SCOPE_NOWHERE, RTN_UNSPEC)
    } else {
        (RTPROT_BOOT, RT_SCOPE_UNIVERSE, RTN_UNICAST)
    }
}

/// Build and send one `0.0.0.0/0` (or `::/0`) route message on `index` and wait
/// for the kernel's ACK.
///
/// `NLM_F_CREATE | NLM_F_REPLACE` on the add rather than plain create so a retry
/// — a second boot of a restored guest, say — overwrites instead of failing
/// `EEXIST`.
fn default_route_request(
    kind: u16,
    flags: u16,
    family: u8,
    gateway: Option<&[u8]>,
    index: u32,
) -> std::result::Result<(), NetlinkFailure> {
    let sock = netlink_socket().map_err(NetlinkFailure::transport)?;
    // The sequence number the ACK must echo. Constant is fine: the socket is
    // opened per call and closed on return, so there is exactly one request
    // outstanding on it ever.
    let sequence: u32 = 1;

    // nlmsghdr(16) + rtmsg(12) + RTA_GATEWAY + RTA_OIF, each attribute
    // 4-byte aligned (every piece here is already a multiple of 4).
    let mut message: Vec<u8> = Vec::with_capacity(64);
    message.extend_from_slice(&0u32.to_ne_bytes()); // nlmsg_len, patched below
    message.extend_from_slice(&kind.to_ne_bytes());
    message.extend_from_slice(&flags.to_ne_bytes());
    message.extend_from_slice(&sequence.to_ne_bytes()); // nlmsg_seq
    message.extend_from_slice(&0u32.to_ne_bytes()); // nlmsg_pid (kernel fills in)

    message.push(family); // rtm_family
    message.push(0); // rtm_dst_len — 0 is the default route
    message.push(0); // rtm_src_len
    message.push(0); // rtm_tos
    message.push(RT_TABLE_MAIN);
    // A delete matches the route rather than describing one, so protocol,
    // scope and type all go out wild — the checkpoint's route may have been
    // installed by anything, and iproute2's own `ip route del` sends exactly
    // these wildcards.
    let (protocol, scope, kind_field) = route_classification(kind);
    message.push(protocol);
    message.push(scope);
    message.push(kind_field);
    message.extend_from_slice(&0u32.to_ne_bytes()); // rtm_flags

    if let Some(gateway) = gateway {
        push_attribute(&mut message, RTA_GATEWAY, gateway);
    }
    push_attribute(&mut message, RTA_OIF, &index.to_ne_bytes());

    let length = message.len() as u32;
    message[..4].copy_from_slice(&length.to_ne_bytes());

    sock.send_to_kernel(&message)
        .map_err(NetlinkFailure::transport)?;
    sock.await_ack(sequence)
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
    ///
    /// The reply is checked to actually be *ours*: from the kernel (source
    /// port 0, not another process), echoing `sequence`, and not truncated.
    /// Nothing can race it today — the socket is fresh per call, joins no
    /// multicast groups, and only the init is running — so this is about being
    /// correct on inspection rather than correct by context.
    fn await_ack(&self, sequence: u32) -> std::result::Result<(), NetlinkFailure> {
        #[repr(C)]
        struct SockaddrNl {
            family: u16,
            pad: u16,
            pid: u32,
            groups: u32,
        }
        let mut buffer = [0u8; 4096];
        let mut source = SockaddrNl {
            family: 0,
            pad: 0,
            pid: u32::MAX,
            groups: 0,
        };
        let mut source_len = std::mem::size_of::<SockaddrNl>() as libc::socklen_t;
        // MSG_TRUNC makes netlink report the message's real size rather than
        // the copied one, so a reply too big for the buffer is detectable
        // instead of being silently read as a short one.
        let read = unsafe {
            libc::recvfrom(
                self.fd,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                libc::MSG_TRUNC,
                (&mut source as *mut SockaddrNl).cast(),
                &mut source_len,
            )
        };
        if read < 0 {
            return Err(NetlinkFailure::transport(format!(
                "read rtnetlink reply: {}",
                std::io::Error::last_os_error()
            )));
        }
        let read = read as usize;
        if read > buffer.len() {
            return Err(NetlinkFailure::transport(format!(
                "rtnetlink reply is {read} bytes, larger than the {} the reply buffer holds",
                buffer.len()
            )));
        }
        if source.pid != 0 {
            return Err(NetlinkFailure::transport(format!(
                "rtnetlink reply came from port {} rather than the kernel",
                source.pid
            )));
        }
        // nlmsghdr(16) + nlmsgerr's leading `int error`.
        if read < 20 {
            return Err(NetlinkFailure::transport(format!(
                "truncated rtnetlink reply ({read} bytes)"
            )));
        }
        let kind = u16::from_ne_bytes([buffer[4], buffer[5]]);
        if kind != NLMSG_ERROR {
            return Err(NetlinkFailure::transport(format!(
                "unexpected rtnetlink reply type {kind}"
            )));
        }
        let echoed = u32::from_ne_bytes([buffer[8], buffer[9], buffer[10], buffer[11]]);
        if echoed != sequence {
            return Err(NetlinkFailure::transport(format!(
                "rtnetlink reply echoes sequence {echoed}, not the {sequence} we sent"
            )));
        }
        let code = i32::from_ne_bytes([buffer[16], buffer[17], buffer[18], buffer[19]]);
        if code == 0 {
            Ok(())
        } else {
            Err(NetlinkFailure::kernel(-code))
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

    /// A real `/proc/net/if_inet6`: two addresses on our device (one global,
    /// one link-local), one on someone else's, and one truncated.
    const IF_INET6_FIXTURE: &str = concat!(
        "fd123456789a0000000000000000000509 02 40 00 80 eth0\n",
        "fd123456789a00000000000000000005 02 40 00 80     eth0\n",
        "fe800000000000000400acfffe100005 02 40 20 80      eth0\n",
        "20010db8000000000000000000000001 03 64 00 80      eth1\n",
        "00000000000000000000000000000001 01 80 10 80        lo\n",
        "deadbeef 02 40 00 80 eth0\n",
    );

    #[test]
    fn if_inet6_yields_only_this_devices_global_addresses() {
        let found = parse_if_inet6(IF_INET6_FIXTURE, "eth0");
        assert_eq!(
            found,
            vec!["fd12:3456:789a::5".parse::<Ipv6Addr>().expect("addr")],
            "link-local, other devices, and unparseable lines are all skipped"
        );
    }

    #[test]
    fn if_inet6_skips_a_device_with_no_addresses() {
        assert!(parse_if_inet6(IF_INET6_FIXTURE, "eth2").is_empty());
    }

    /// The scope column is `fields[3]`, and reading the wrong one is a silent
    /// wrong answer rather than an error — so pin that a global address whose
    /// *prefix* happens to equal the link-local scope value still survives.
    #[test]
    fn if_inet6_reads_scope_from_the_scope_column() {
        // prefix 0x20 (32), scope 0x00 (global): must be kept.
        let line = "20010db8000000000000000000000009 02 20 00 80 eth0\n";
        assert_eq!(
            parse_if_inet6(line, "eth0"),
            vec!["2001:db8::9".parse::<Ipv6Addr>().expect("addr")]
        );
    }

    #[test]
    fn macs_parse_into_the_ioctl_payload() {
        assert_eq!(
            parse_mac("06:00:ac:10:00:05").expect("parse"),
            [0x06, 0x00, 0xac, 0x10, 0x00, 0x05]
        );
        assert_eq!(parse_mac(" 06:00:AC:10:00:05 ").expect("parse")[2], 0xac);
        assert!(parse_mac("06:00:ac:10:00").is_err(), "too few octets");
        assert!(
            parse_mac("06:00:ac:10:00:05:07").is_err(),
            "too many octets"
        );
        assert!(parse_mac("06-00-ac-10-00-05").is_err(), "wrong separator");
        assert!(parse_mac("06:00:ac:10:00:zz").is_err(), "not hex");
    }

    /// The MAC lands in `sa_data`, after the two-byte hardware-type family —
    /// getting that offset wrong would silently program the first two octets
    /// into the family field.
    #[test]
    fn hardware_address_sits_after_the_family_in_ifreq() {
        let mut req = IfReq::new("eth0").expect("ifreq");
        req.data[..2].copy_from_slice(&ARPHRD_ETHER.to_ne_bytes());
        req.data[2..8].copy_from_slice(&parse_mac("06:00:ac:10:00:05").expect("parse"));
        assert_eq!(u16::from_ne_bytes([req.data[0], req.data[1]]), ARPHRD_ETHER);
        assert_eq!(&req.data[2..8], &[0x06, 0x00, 0xac, 0x10, 0x00, 0x05]);
    }

    /// A delete describes no route of its own — it matches one — so protocol,
    /// scope and type all go out as wildcards. Sending the *add* triple on a
    /// delete is the classic way to get a silent `ESRCH` against a route the
    /// checkpoint installed under a different protocol.
    #[test]
    fn a_route_delete_is_all_wildcards() {
        assert_eq!(
            route_classification(RTM_DELROUTE),
            (RTPROT_UNSPEC, RT_SCOPE_NOWHERE, RTN_UNSPEC)
        );
        assert_eq!(
            route_classification(RTM_NEWROUTE),
            (RTPROT_BOOT, RT_SCOPE_UNIVERSE, RTN_UNICAST)
        );
    }

    /// The kernel reports these as "already in the state you asked for", and
    /// they are: a route the address flush already took with it. Decided on
    /// the errno rather than its rendering, so neither a locale nor a libc
    /// wording change can turn a benign result into a failed re-identification.
    #[test]
    fn a_missing_route_is_not_a_delete_failure() {
        assert!(tolerated_route_delete_errno(Some(libc::ESRCH)));
        assert!(tolerated_route_delete_errno(Some(libc::ENOENT)));
        assert!(!tolerated_route_delete_errno(Some(libc::EPERM)));
        // A transport or framing failure carries no kernel verdict, so it is
        // not something to swallow.
        assert!(!tolerated_route_delete_errno(None));
    }

    #[test]
    fn a_netlink_failure_keeps_the_errno_beside_its_message() {
        let kernel = NetlinkFailure::kernel(libc::ESRCH);
        assert_eq!(kernel.errno, Some(libc::ESRCH));
        assert!(kernel.to_string().contains("the kernel rejected it"));

        let transport = NetlinkFailure::transport("truncated reply".into());
        assert_eq!(transport.errno, None);
        assert_eq!(transport.to_string(), "truncated reply");
    }

    #[test]
    fn absolute_guest_paths_land_under_the_new_root() {
        assert_eq!(
            join_absolute(Path::new("/newroot"), "/etc/hosts"),
            Path::new("/newroot/etc/hosts")
        );
    }
}
