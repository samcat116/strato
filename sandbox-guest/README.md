# Strato sandbox guest image

The guest half of a Strato sandbox (umbrella [#410], this piece [#419]): the
artifacts an agent hosts to turn a booted Firecracker microVM into a running
container workload. Two artifacts per architecture:

- **`vmlinux-<arch>`** — a minimal maintained Linux kernel configured for
  Firecracker (virtio-mmio, virtio-vsock, ext4, serial console; no modules).
  On aarch64 this file is the arm64 `Image` format.
- **`initramfs-<arch>.cpio.gz`** — a gzipped cpio holding a single static
  binary at `/init`: [`strato-sandbox-init`](init/), the PID-1 guest init and
  vsock control agent.

A `guest.json` manifest describes them (versions, checksums, per-arch default
boot args) and, at **manifest schema v2**, what this guest build can *do*:

```json
{ "schemaVersion": 2, "version": "...", "capabilities": ["network"], "artifacts": [...] }
```

Together they install into `sandbox_guest_image_path` (default
`/var/lib/strato/sandbox/guest`); their presence is what lights up an agent's
`sandbox_runtime` capability, and `capabilities` is what lights up
`sandbox_networking` (STR-103). The two are separate because this image is
distributed separately from the agent binary — an up-to-date agent paired with
a guest that predates the config drive's `network` block would refuse every
networked sandbox, so the control plane withholds their NICs instead. The agent
reads manifest schema `1...2`, and a v1 manifest advertises nothing rather than
failing (see `StratoAgentCore/SandboxGuestImage.swift` and
`SandboxRuntimeProbe`).

**Adding a capability**: name it in `build.sh`'s manifest *and* teach the agent
probe to read it. Never advertise one the initramfs cannot actually serve — the
list is the only evidence the host has.

## What the init does

Booted by Firecracker with our kernel + initramfs, `strato-sandbox-init` runs
as PID 1 and:

1. mounts `/proc`, `/sys`, `/dev`;
2. reads the **config drive** (a raw block device, default `/dev/vdb`, named on
   the kernel cmdline as `strato.config=<dev>`) carrying the merged OCI process
   spec + guest params as JSON;
3. brings up `lo`, and — when the config drive carries a `network` block —
   the NIC: matched by MAC, addressed statically, given its default route and
   MTU ([STR-101]);
4. mounts the flattened container rootfs ([#418]) from its block device (default
   `/dev/vda`), writes `/etc/resolv.conf` and `/etc/hosts` into it, and
   `switch_root`s onto it, leaving that image otherwise **pristine** — the
   init is never written into it;
5. resolves the process to run by merging the image's OCI config with the
   sandbox's overrides (entrypoint/cmd/env/workdir/user);
6. execs the workload as a child (stdin `/dev/null`; stdout/stderr captured
   via pipes, mirrored byte-for-byte to the console **and** retained in a
   256 KiB ring buffer), keeping PID 1 as a forever-running reaper that routes
   every child's exit code;
7. serves the **vsock** control surface — health `ping` / `get_status`,
   interactive `exec` sessions (PTY or pipes), and `stream_logs` follow
   streams of the workload's captured stdio ([#423]).

### Config-drive schema (the host's contract — produced by [#421])

Raw JSON at the start of the config block device, NUL-padded to the device
size (no filesystem). Fields: see [`init/src/config.rs`](init/src/config.rs)
(`GuestConfig`). Shape:

```json
{
  "schema_version": 2,
  "sandbox_id": "…",
  "identity_nonce": "…",
  "rootfs": { "device": "/dev/vda", "fstype": "ext4", "readonly": false },
  "vsock_port": 1024,
  "image_config": { "Env": ["PATH=…"], "Entrypoint": ["/app"], "Cmd": ["…"],
                    "WorkingDir": "/", "User": "0:0" },
  "overrides": { "entrypoint": null, "cmd": null, "env": {"K":"V"},
                 "workdir": null, "user": null },
  "hostname": "strato-0f1e2d3c4b5a",
  "network": {
    "mac_address": "06:00:ac:10:00:05",
    "ipv4": { "address": "172.16.0.5", "prefix_length": 24, "gateway": "172.16.0.1" },
    "ipv6": { "address": "fd12:3456:789a::5", "prefix_length": 64, "gateway": "fd12:3456:789a::1" },
    "mtu": 1442,
    "nameservers": ["172.16.0.2"],
    "search_domains": ["proj.strato.internal"]
  }
}
```

`network` is absent for a sandbox with no NIC (and for warm-start templates,
which carry no network device at all); everything inside it but the addresses
is optional. `hostname` sits *beside* it rather than inside it, because a
hostname belongs to the sandbox and not to its NIC — nesting it would leave two
sandboxes of one image differing in name by NIC presence alone.

**The version stamped is the minimum the document needs, not the newest the
host knows.** A network-free document is stamped v1 even by an agent that can
write v2, and the guest accepts anything in `1...SCHEMA_VERSION` — so an
older guest image keeps booting sandboxes whose drives carry nothing it does
not understand. A drive carrying a `network` block is stamped v2, and a guest
that predates it refuses with `unsupported config-drive schema version` on the
serial console rather than booting a sandbox whose NIC it would silently
ignore. Since the guest image is distributed separately from the agent, that is
what keeps a lagging image from being a fleet-wide outage while still failing
loudly at the point it matters.

In practice that refusal should never fire: the manifest's `network`
capability, advertised at every agent registration, means the control plane
does not send a NIC to a host whose guest cannot configure one (STR-103). This
is the last line of defence, not the first.

### Guest networking ([STR-101])

Static, not DHCP: the control plane's IPAM has already picked the address by
the time the microVM boots, so a DHCP exchange would spend a cold-start round
trip — and an extra binary in a size-optimized initramfs — rediscovering it.
OVN's DHCP responder is still programmed for the port, so an image that runs
its own client keeps working; the guest just does not depend on one.

Bring-up is hand-rolled `ioctl` plus one rtnetlink `RTM_NEWROUTE` per family
rather than a crate, for the same size reason. It is fatal on failure: the
host cannot tell a half-configured interface from a healthy one, so a sandbox
that reports `running` has to actually be on its network. The two files
written into the rootfs (`/etc/resolv.conf`, `/etc/hosts`) are best effort by
contrast — a read-only rootfs is a legitimate shape — and `/etc` is created
rather than assumed, since scratch and distroless images may not have one.

Three things are *not* gated on having a NIC, because their reasons are not
about networking: `lo` comes up for every sandbox (workloads bind `127.0.0.1`
with no NIC in sight), `/etc/hosts` is written for every sandbox (a scratch
image with no host table cannot resolve `localhost` either way), and the
hostname is set for every sandbox (it is the sandbox's name, not the NIC's).
A warm-launched sandbox gets its hostname over the `launch` control request
instead of the config drive, since its guest booted from the *template's*
drive.

Testable end to end with a hand-plugged TAP on a dev host: boot the guest with
a `network` block and a `tap` device, no OVN or control plane involved.

### Re-addressing a restored guest ([STR-104])

A guest that came out of *someone else's* checkpoint — a warm template shared
across sandboxes, or a fork of another sandbox's snapshot — holds that guest's
MAC and address in kernel memory, and the config drive staged for it is not the
one its page cache describes. So its NIC is configured over vsock instead, on
the `launch`/`reidentify` request that also delivers its identity (control
protocol v4). The host has already repointed the virtio device at this
sandbox's TAP before the guest was resumed.

The guest side is a flush-and-reapply, in an order that matters: remove the
addresses first (which takes the routes that depended on them with them), then
set the MAC with the link down — the kernel refuses `SIOCSIFHWADDR` on a
running device — then MTU, link up, addresses, routes, resolver files. The MAC
is not cosmetic: OVN's `port_security` filters on the source MAC of the frame,
so a fork that kept the source's would be up, addressed, and silently dropped
upstream. Fatal on failure like the cold path, and idempotent, because the host
retries: the device is found by the *new* MAC first (an already-applied retry),
then the previously applied one, then — with exactly one non-loopback interface
present — that one.

### vsock control protocol (v4)

Newline-delimited JSON, host connects to the guest port; one guest thread per
connection. See [`init/src/protocol.rs`](init/src/protocol.rs). `pong` carries
`control_protocol_version`, which is how a host tells a new guest from an older
init frozen inside a checkpoint — v3 added `sync_clock`, `launch` and
`reidentify`; v4 ([STR-104]) put a `network` block on the latter two. The
**first request on a connection determines its role**:

- **Control** — `{"type":"ping"}` → `{"type":"pong",…}`;
  `{"type":"get_status"}` →
  `{"type":"status","state":"running|exited","exit_code":…}` (the v1 surface,
  unchanged; the connection keeps serving requests). Every control response
  echoes `sandbox_id` + `nonce` so a host can re-identify a guest after a
  snapshot/resume (phase 4, [#426]).
- **Exec session** ([#423]) —
  `{"type":"exec","argv":[…],"env":{…},"cwd":…,"tty":…,"rows":…,"cols":…}`
  runs a command in the workload's context (its resolved env with the
  request's merged over it, its cwd unless overridden, its uid/gid). The
  guest answers `{"type":"exec_started"}` (or `{"type":"error",…}`), streams
  `{"type":"output","stream":"stdout|stderr","data":"<base64>"}` chunks, and
  accepts interleaved `{"type":"stdin","data":"<base64>"}`,
  `{"type":"stdin_eof"}`, and `{"type":"resize","rows":…,"cols":…}`. With
  `tty:true` the child gets a PTY in a new session (all output reported as
  `stdout`); otherwise three pipes in its own process group. After the child
  is reaped and output flushed the guest sends one terminal
  `{"type":"exec_exit","exit_code":N}` (signal N → `128+N`) and closes. A
  host disconnect before that SIGKILLs the exec process group.
- **Log follow stream** ([#423]) — `{"type":"stream_logs","since_seq":N}`
  replays retained workload stdio records (`seq` starts at 1, monotonic
  across streams; already-evicted records are silently skipped) and then
  follows new output forever as
  `{"type":"log","seq":…,"stream":"stdout|stderr","data":"<base64>"}` lines.

## Building

Requires a Linux build host (kernel builds are Linux-only). Use the pinned
toolchain image for reproducibility:

```sh
docker build -f Dockerfile.build -t strato-sandbox-guest-build .
docker run --rm -v "$PWD:/src" -w /src strato-sandbox-guest-build \
  ./build.sh --arch x86_64,aarch64 --out /src/build/out
```

Or, on a suitably provisioned host, directly:

```sh
./build.sh --arch x86_64 --out ./build/out    # kernel + initramfs + guest.json
```

The init's portable logic (config merge, vsock protocol, resolver-file
rendering) is unit-tested on any host, including macOS/CI:

```sh
cargo test --manifest-path init/Cargo.toml --lib
```

The Linux-only halves — the network ioctls and the rtnetlink route — have unit
tests too (`cargo test` on a Linux host runs them), but their real check is a
namespace, which needs no microVM, no OVN, and no control plane:

```sh
sudo ip netns add guest-test
sudo ip netns exec guest-test ip link add veth0 type veth peer name veth1
sudo ip netns exec guest-test ip link set veth0 address 06:00:ac:10:00:05
# …drive net::configure_interface with a matching config, then:
sudo ip netns exec guest-test ip -br addr; sudo ip netns exec guest-test ip route
sudo ip netns del guest-test
```

## Versioning & publishing

`guest.json` pins `version` (`<kernel>+init<crate>`) and `gitSHA`. CI
(`.github/workflows/sandbox-guest.yaml`) builds both arches on a tag, uploads
the artifacts + `.sha256` sidecars as GitHub Release assets, and publishes a
`sandbox-guest-manifest.json` (download URLs + checksums) mirroring the agent
release flow. Install onto a host with `deploy/agent/install.sh
--sandbox-guest`, which downloads the published `sandbox-guest-<arch>.tar.gz`
into the agent's `sandbox_guest_image_path` (default
`/var/lib/strato/sandbox/guest`).

## Kernel version

Pinned in [`kernel/LINUX_VERSION`](kernel/LINUX_VERSION) (currently the 6.1 LTS
series, matching what Firecracker's CI guest configs track). Bump the version
and its sha256 together.

[#410]: https://github.com/samcat116/strato/issues/410
[#418]: https://github.com/samcat116/strato/issues/418
[#419]: https://github.com/samcat116/strato/issues/419
[#421]: https://github.com/samcat116/strato/issues/421
[#423]: https://github.com/samcat116/strato/issues/423
[#426]: https://github.com/samcat116/strato/issues/426
[STR-101]: https://github.com/samcat116/strato/issues/846
[STR-104]: https://github.com/samcat116/strato/issues/849
