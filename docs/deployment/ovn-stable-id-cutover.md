# OVN stable network ID cutover

STR-226 removes the always-reachable migrations that renamed tenant logical
switches and adopted managed DHCP rows by network name. Before deploying a
version containing that removal, every OVN northbound database must have been
converged by the preceding, migration-capable agent version.

Run the read-only inventory against each site's northbound database:

```sh
agent/scripts/ovn-stable-id-preflight.sh
```

The default is the local `ovn-nbctl`. For a remote database, set `OVN_NBCTL`
to the path of a small executable wrapper containing the database and TLS
flags. The script only issues OVSDB `list` queries. It reports:

- Strato-created tenant switches whose names are not `net-<network UUID>`.
- `strato-managed` DHCP rows with no `network-id` external ID.

If either list is non-empty, leave the old agent deployed and trigger a full
authoritative network reconcile for the affected site. That reconcile renames
each switch in place and stamps each DHCP row without changing its OVSDB UUID,
preserving live port references. Repeat the inventory until it exits zero.

After it passes, capture one more full network reconcile and verify its OVN
transaction log contains no logical-switch rename, DHCP row adoption, or
delete/create replacement for tenant switches and DHCP rows. Only then deploy
the STR-226 version. The post-deployment check is the same command: any result
is an unsupported pre-cutover object and must be investigated rather than
silently adopted by network name.

Stable NIC0 names are deliberately outside this cutover. Do not rename host
interfaces or logical switch ports as part of the inventory or remediation.
