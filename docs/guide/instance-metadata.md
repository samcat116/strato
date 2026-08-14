# Instance metadata and VM bootstrap

New x86_64 QEMU VMs use the instance metadata service (IMDS) for cloud-init by
default. ARM64 QEMU and Firecracker VMs default to the ISO path. An IMDS-backed
VM's seed ISO contains only the network configuration needed to reach
`169.254.169.254` and a NoCloud `seedfrom` stub; the guest fetches its hostname,
SSH keys, and user data from the agent after the network is online.

Choose **Seed ISO** in the create-VM dialog, or pass
`--metadata-source iso` to `strato vm create`, when an image cannot use the
network NoCloud datasource. This writes the complete, immutable cloud-init
payload to the ISO instead. A VM using IMDS must leave its instance metadata
service enabled and must attach to at least one network with metadata enabled.

## Existing VMs do not change

The default applies only when an x86_64 QEMU VM is created without an explicit
`metadataSource`. Every existing VM keeps the value stored when it was created,
including VMs created before the field existed, which remain on `iso`. Upgrading
Strato never rewrites those rows or regenerates their seed media.

The source cannot be changed in place. It determines the contents of the seed
ISO and the discovery information cloud-init sees at first boot. Changing only
the database value would leave the persisted VM and its seed media disagreeing,
so it is not a supported migration.

## Move an existing VM to IMDS

1. Record the VM's image, sizing, networks, security groups, SSH keys, user
   data, and attached data volumes.
2. Create a replacement QEMU VM from the same image. Select **Instance metadata
   service**, pass `--metadata-source imds`, or set
   `"metadataSource": "imds"` in the create API request.
3. Restore or copy application data through your normal backup workflow, and
   reattach any durable data volumes that should move to the replacement.
4. Start the replacement and verify cloud-init before moving traffic:

   ```bash
   sudo cloud-init status --wait --long
   sudo cloud-init query --all
   sudo grep -F DataSourceNoCloudNet /var/log/cloud-init.log
   ```

   The status must finish successfully, the query must report the replacement
   VM's instance ID and hostname, and the log must show NoCloud network
   retrieval from `169.254.169.254`. The query and logs can contain user data,
   SSH keys, and a per-VM capability in the full seed URL; redact them before
   sharing the output.
5. Move service traffic to the replacement. Delete the old VM only after the
   replacement and its data have been verified.

IMDS metadata can change while a VM is running, but cloud-init does not
continuously reapply it. A guest sees updated tags and SSH keys the next time
its datasource runs, such as after a reboot or an explicit cloud-init clean and
rerun. Use a guest agent when an update must take effect immediately.
