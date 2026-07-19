# FRR for floating-IP BGP advertisement (issue #344)

OVN's native dynamic routing (≥ 25.03) advertises floating IPs and tenant
routes northbound — but **OVN does not speak BGP**. On each egress host (the
site's network-controller agent, which holds the gateway chassis), an FRR
daemon peers with the fabric and redistributes what OVN installs:

1. The Strato agent sets `dynamic-routing=true` +
   `dynamic-routing-redistribute` on each uplinked logical router, and
   `routing-protocols=BGP` / `dynamic-routing-maintain-vrf` on its gateway
   port (enable via `[ovn_dynamic_routing]` in the agent config).
2. `ovn-northd` fills the southbound `Advertised_Route` table;
   `ovn-controller` installs those routes into a Linux **VRF** on the host.
3. FRR runs `bgpd` with `redistribute connected` (or `redistribute kernel`)
   inside that VRF and advertises the routes to your peers. Inbound routes it
   learns flow back through OVN's `Learned_Route` table.

The strato-agent image ships FRR but leaves it unconfigured and not running —
BGP peering (AS numbers, neighbors, filters) is site-specific operator
configuration.

## Quick start (on the egress host)

1. Enable dynamic routing in `/etc/strato/config.toml`:

   ```toml
   [ovn_dynamic_routing]
   enabled = true
   redistribute = ["connected", "nat"]   # "nat" advertises floating IPs
   vrf_name = "ovnvrf"
   maintain_vrf = true
   routing_protocols = ["BGP"]
   ```

2. Adapt `frr.conf.example` (this directory) to your fabric — AS numbers,
   neighbor addresses, and the VRF name must match `vrf_name` above — and
   install it as `/etc/frr/frr.conf`. Enable `bgpd` in `/etc/frr/daemons`.

3. Restart FRR and verify:

   ```sh
   vtysh -c 'show bgp vrf ovnvrf summary'
   vtysh -c 'show ip bgp vrf ovnvrf'          # floating IPs appear as /32s
   ovn-sbctl list Advertised_Route            # what OVN is exporting
   ```

## Reachability without BGP (tier 1: static routes)

BGP is optional. Floating IPs work with plain static routing: point the
floating pool's CIDR at the agent's uplink IP (`[ovn_uplink] external_cidr`)
on your upstream router. If the pool is carved from the uplink subnet itself,
no route is needed at all — the VM's chassis answers ARP for the floating
address directly (distributed NAT).
