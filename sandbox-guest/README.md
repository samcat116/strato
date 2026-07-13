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
boot args). Together they install into `sandbox_guest_image_path` (default
`/var/lib/strato/sandbox/guest`); their presence is what lights up an agent's
`sandbox_runtime` capability (see `StratoAgentCore/SandboxGuestImage.swift` and
`SandboxRuntimeProbe`).

## What the init does

Booted by Firecracker with our kernel + initramfs, `strato-sandbox-init` runs
as PID 1 and:

1. mounts `/proc`, `/sys`, `/dev`;
2. reads the **config drive** (a raw block device, default `/dev/vdb`, named on
   the kernel cmdline as `strato.config=<dev>`) carrying the merged OCI process
   spec + guest params as JSON;
3. mounts the flattened container rootfs ([#418]) from its block device (default
   `/dev/vda`) and `switch_root`s onto it, leaving that image **pristine** — the
   init is never written into it;
4. resolves the process to run by merging the image's OCI config with the
   sandbox's overrides (entrypoint/cmd/env/workdir/user);
5. execs the workload as a child, keeping PID 1 to reap zombies;
6. serves a tiny **vsock** control surface — health `ping` and `get_status`
   (which returns the workload's exit code once it ends).

Exec/stdio streaming is deliberately out of scope for v1 (phase 2, [#423]).

### Config-drive schema (the host's contract — produced by [#421])

Raw JSON at the start of the config block device, NUL-padded to the device
size (no filesystem). Fields: see [`init/src/config.rs`](init/src/config.rs)
(`GuestConfig`). Shape:

```json
{
  "schema_version": 1,
  "sandbox_id": "…",
  "identity_nonce": "…",
  "rootfs": { "device": "/dev/vda", "fstype": "ext4", "readonly": false },
  "vsock_port": 1024,
  "image_config": { "Env": ["PATH=…"], "Entrypoint": ["/app"], "Cmd": ["…"],
                    "WorkingDir": "/", "User": "0:0" },
  "overrides": { "entrypoint": null, "cmd": null, "env": {"K":"V"},
                 "workdir": null, "user": null }
}
```

### vsock control protocol

Newline-delimited JSON, host connects to the guest port. See
[`init/src/protocol.rs`](init/src/protocol.rs). v1: `{"type":"ping"}` →
`{"type":"pong",…}`; `{"type":"get_status"}` →
`{"type":"status","state":"running|exited","exit_code":…}`. Every response
echoes `sandbox_id` + `nonce` so a host can re-identify a guest after a
snapshot/resume (phase 4, [#426]).

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

The init's portable logic (config merge, vsock protocol) is unit-tested on any
host, including macOS/CI:

```sh
cargo test --manifest-path init/Cargo.toml --lib
```

## Versioning & publishing

`guest.json` pins `version` (`<kernel>+init<crate>`) and `gitSHA`. CI
(`.github/workflows/sandbox-guest.yaml`) builds both arches on a tag, uploads
the artifacts + `.sha256` sidecars as GitHub Release assets, and publishes a
`sandbox-guest-manifest.json` (download URLs + checksums) mirroring the agent
release flow. Install onto a host with `task install-sandbox-guest`.

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
