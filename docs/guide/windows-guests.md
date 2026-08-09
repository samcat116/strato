# Windows Guests

Windows 11 and Windows Server 2025 refuse to install on a machine without
UEFI Secure Boot and a TPM 2.0. Strato models both as per-VM options
(`secureBoot` and `tpm` on VM create), realized by the agent as a signed EDK2
firmware pair and a per-VM `swtpm` process. This page covers what you have to
put on the hypervisor node, what to ask for at create time, and what is still
manual.

## Host prerequisites

Both features are properties of the *node*, not of Strato: the agent can only
attach firmware and a TPM that exist on the host it runs on.

```bash
# Debian / Ubuntu hypervisor node
apt install ovmf swtpm swtpm-tools
```

`ovmf` provides the signed EDK2 build (`OVMF_CODE_4M.secboot.fd`) and, more
importantly, the variable store with Microsoft's keys pre-enrolled
(`OVMF_VARS_4M.ms.fd`). The pre-enrolled store is the part that matters:
Windows validates its bootloader against Microsoft's KEK/db, and an empty
variable store leaves the guest in Secure Boot *setup mode* with nothing
trusted, which looks like a Secure Boot failure but is really an empty
keyring. On Fedora/RHEL the equivalent files are under `/usr/share/edk2/ovmf/`
and the agent finds them without configuration. For arm64 guests, install
`qemu-efi-aarch64` for the AAVMF pair.

The agent auto-detects the usual distro locations. Override them only if your
files live elsewhere — see `firmware_code_path`, `firmware_vars_template`,
`secure_boot_firmware_code_path` and `secure_boot_firmware_vars_template` in
[`config.toml.example`](https://github.com/samcat116/strato/blob/main/config.toml.example).
There is no `swtpm` path to configure: libvirt starts and supervises swtpm per
domain, and the agent asks libvirt whether it can.
Each firmware pair must be set together or the agent refuses to start: a 4MB
code image paired with a 2MB variable store produces a firmware that fails to
boot in a way that looks like a corrupt guest image, so the configuration is
rejected rather than half-applied.

Restart **libvirtd** and then the agent after installing the packages. libvirtd
caches host capabilities, so it keeps reporting no TPM backend until it restarts
(`systemctl restart virtqemud.socket virtqemud`, or `libvirtd` on a monolithic
install); the agent's capabilities are reported at registration, so it keeps
advertising the old answer until it re-registers.

## Checking whether a node is TPM-capable

A VM that asks for a TPM only places on a node that has one to give. Two ways
to see which nodes qualify:

- **UI**: **Agents** → the node → **Capabilities**. A capable node lists
  `vtpm`.
- **API**: `GET /api/agents` returns `tpmCapable` per agent.

If no node qualifies, the create fails asynchronously with a message naming
the fix rather than silently placing the VM somewhere that would boot it
without a TPM — see [Scheduler](/architecture/scheduler) for why this is a
hard constraint. Secure Boot on its own needs no special capability, only an
agent new enough to speak wire protocol v17.

## Preparing the image

Windows install media needs the virtio drivers, because the installer cannot
see a virtio-blk disk or a virtio-net NIC without them. Strato does **not**
automate this today:

1. Upload the Windows installation ISO as an image.
2. Download the [virtio-win driver
   ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) and
   upload it as a second image.
3. Create the VM from the Windows ISO, then attach the virtio-win image as a
   second, read-only volume before first boot.
4. In Windows Setup, at "Where do you want to install Windows?", choose **Load
   driver** and point it at `viostor\<version>\amd64` on the virtio-win
   volume. Load the NetKVM driver the same way if the installer needs the
   network.

Automating the driver injection is explicitly out of scope for now; expect to
do steps 2–4 by hand for each install. Once Windows is installed and the
guest tools are in place, the resulting disk image can be captured and reused
without repeating this.

## Recommended spec

```json
POST /api/vms
{
  "name": "win-2025",
  "imageId": "…",
  "projectId": "…",
  "cpu": 4,
  "memory": 8589934592,
  "disk": 68719476736,
  "secureBoot": true,
  "tpm": true
}
```

In the UI these are the two switches in the **Windows / Secure Boot** section
of the create-VM dialog. Both default off, and both are unavailable for
Firecracker images — Firecracker has no UEFI firmware and no TPM device, so
the API rejects the combination with a 400 rather than booting a machine that
does not match what was asked for.

You also want the **graphics console**. Windows Setup is a graphical installer
and is unusable over a serial console, so turn on **Display** in the create-VM
dialog alongside the two switches above. Setup is then driven from the VM's
**Display** tab, keyboard and mouse included. Enable it at creation: the display
device is fixed in the hypervisor process's arguments, so a VM created without
one cannot gain it later.

## What the VM actually gets

Secure Boot boots the signed firmware on a `q35` machine with SMM enabled and
the pflash variable store marked secure, so the guest cannot rewrite the key
database from inside. The variable store itself is a per-VM copy
(`nvram.fd` in the VM's directory), which means enrolled keys and UEFI boot
entries survive a restart — the same fix incidentally repaired non-persistent
boot entries for Linux guests, which previously ran with no writable varstore
at all.

The TPM is a real emulated TPM 2.0, not a stub: one `swtpm` process per VM,
with state under the VM's own directory. BitLocker, Windows Hello, and
attestation all work against it, and the sealed state persists for the life of
the VM.

## Known limitations

- **Secure Boot is Linux-hypervisor-node only.** macOS agents get QEMU's EDK2
  build from Homebrew, which is unsigned and has no pre-enrolled key store, so
  there is nothing to boot in Secure Boot mode. A Secure Boot create on a
  macOS-only fleet fails loudly rather than degrading.
- **No virtio driver automation.** The driver ISO is attached and loaded by
  hand, per the steps above.
- **The display must be chosen at creation.** A VM created without one cannot
  gain a display later — recreate it. (The serial console is always present
  either way.)
- **swtpm belongs to libvirt, not to the agent.** libvirtd starts and
  supervises one swtpm per domain and keeps its state under
  `/var/lib/libvirt/swtpm/`, so restarting or upgrading an agent leaves running
  Windows VMs alone, and a swtpm that dies is libvirt's to notice. The state
  survives a VM stop/start, so nothing sealed to the TPM (BitLocker keys
  included) is lost.
