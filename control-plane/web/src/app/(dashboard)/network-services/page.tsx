"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Globe2, Network, Scale, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { useNetworks, usePermissions, useSites, useVMs } from "@/lib/hooks";
import {
  dnsApi,
  floatingIPsApi,
  loadBalancersApi,
  type CreateDNSRecordRequest,
} from "@/lib/api/platform-services";
import { useAuth, useOrganization, useProjectContext } from "@/providers";

function SelectField({
  id,
  label,
  value,
  onChange,
  children,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  children: React.ReactNode;
}) {
  return (
    <div>
      <Label htmlFor={id}>{label}</Label>
      <select
        id={id}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
        required
      >
        {children}
      </select>
    </div>
  );
}

export default function NetworkServicesPage() {
  const { currentProject } = useProjectContext();
  const { currentOrg } = useOrganization();
  const { user } = useAuth();
  const projectId = currentProject?.id;
  const queryClient = useQueryClient();
  const networksQuery = useNetworks(projectId);
  const sitesQuery = useSites();
  const vmsQuery = useVMs();

  const [lbName, setLBName] = useState("");
  const [lbNetwork, setLBNetwork] = useState("");
  const [selectedLB, setSelectedLB] = useState("");
  const [listenerPort, setListenerPort] = useState("443");
  const [backendPort, setBackendPort] = useState("443");
  const [backendIP, setBackendIP] = useState("");
  const [poolName, setPoolName] = useState("");
  const [poolCIDR, setPoolCIDR] = useState("");
  const [poolGateway, setPoolGateway] = useState("");
  const [poolSite, setPoolSite] = useState("");
  const [allocationPool, setAllocationPool] = useState("");
  const [floatingVMs, setFloatingVMs] = useState<Record<string, string>>({});
  const [zoneName, setZoneName] = useState("");
  const [recordZone, setRecordZone] = useState("");
  const [recordName, setRecordName] = useState("@");
  const [recordType, setRecordType] =
    useState<CreateDNSRecordRequest["type"]>("A");
  const [recordValue, setRecordValue] = useState("");
  const [zoneNetwork, setZoneNetwork] = useState("");
  const [zonePrimary, setZonePrimary] = useState(false);

  const { permissions } = usePermissions(
    projectId
      ? [
          { key: "create_lb", action: "loadbalancer:create", node: { type: "project", id: projectId } },
          { key: "allocate_ip", action: "floatingip:create", node: { type: "project", id: projectId } },
          { key: "create_zone", action: "dns:create", node: { type: "project", id: projectId } },
        ]
      : []
  );

  const loadBalancersQuery = useQuery({
    queryKey: ["load-balancers", { projectId }],
    queryFn: ({ signal }) => loadBalancersApi.list(projectId!, signal),
    enabled: !!projectId,
    refetchInterval: 10_000,
  });
  const poolsQuery = useQuery({
    queryKey: ["floating-ip-pools"],
    queryFn: ({ signal }) => floatingIPsApi.listPools(signal),
  });
  const floatingIPsQuery = useQuery({
    queryKey: ["floating-ips", { projectId }],
    queryFn: ({ signal }) => floatingIPsApi.list(projectId!, signal),
    enabled: !!projectId,
  });
  const zonesQuery = useQuery({
    queryKey: ["dns-zones", { projectId }],
    queryFn: ({ signal }) => dnsApi.listZones(projectId!, signal),
    enabled: !!projectId,
  });
  const recordsQuery = useQuery({
    queryKey: ["dns-records", { zoneId: recordZone }],
    queryFn: ({ signal }) => dnsApi.listRecords(recordZone, signal),
    enabled: !!recordZone,
  });
  const { permissions: resourcePermissions } = usePermissions([
    ...(loadBalancersQuery.data ?? []).flatMap((lb) => [
      { key: `lb_update:${lb.id}`, action: "loadbalancer:update", node: { type: "load_balancer", id: lb.id } },
      { key: `lb_delete:${lb.id}`, action: "loadbalancer:delete", node: { type: "load_balancer", id: lb.id } },
    ]),
    ...(floatingIPsQuery.data ?? []).flatMap((address) => [
      { key: `ip_attach:${address.id}`, action: "floatingip:attach", node: { type: "floating_ip", id: address.id } },
      { key: `ip_detach:${address.id}`, action: "floatingip:detach", node: { type: "floating_ip", id: address.id } },
      { key: `ip_release:${address.id}`, action: "floatingip:release", node: { type: "floating_ip", id: address.id } },
    ]),
    ...(zonesQuery.data ?? []).flatMap((zone) => [
      { key: `zone_create:${zone.id}`, action: "dns:create", node: { type: "dns_zone", id: zone.id } },
      { key: `zone_attach:${zone.id}`, action: "dns:attach", node: { type: "dns_zone", id: zone.id } },
      { key: `zone_detach:${zone.id}`, action: "dns:detach", node: { type: "dns_zone", id: zone.id } },
      { key: `zone_delete:${zone.id}`, action: "dns:delete", node: { type: "dns_zone", id: zone.id } },
    ]),
    ...(recordsQuery.data ?? []).map((record) => ({
      key: `record_delete:${record.id}`, action: "dns:delete", node: { type: "dns_record", id: record.id },
    })),
  ]);

  const refresh = () => {
    for (const key of ["load-balancers", "floating-ip-pools", "floating-ips", "dns-zones", "dns-records"]) {
      void queryClient.invalidateQueries({ queryKey: [key] });
    }
  };
  const mutation = useMutation({
    mutationFn: (work: () => Promise<unknown>) => work(),
    onSuccess: () => {
      refresh();
      toast.success("Network service updated");
    },
    onError: (error) => toast.error(error.message),
  });
  const confirmMutation = (message: string, work: () => Promise<unknown>) => {
    if (window.confirm(message)) mutation.mutate(work);
  };

  if (!currentProject) {
    return <p className="py-12 text-center text-muted-foreground">Select a project first.</p>;
  }

  const error =
    loadBalancersQuery.error ?? poolsQuery.error ?? floatingIPsQuery.error ??
    zonesQuery.error ?? networksQuery.error ?? vmsQuery.error;

  const projectVMs = (vmsQuery.data ?? []).filter((vm) => vm.projectId === currentProject.id);
  const managedLB = (loadBalancersQuery.data ?? []).find((lb) => lb.id === selectedLB);

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Network services</h1>
        <p className="text-muted-foreground">Load balancing, public addresses, and DNS for {currentProject.name}</p>
      </div>
      <QueryErrorNotice resource="network services" error={error} hasData={loadBalancersQuery.data !== undefined || zonesQuery.data !== undefined} onRetry={refresh} />

      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><Scale className="h-5 w-5" />Load balancers</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          {permissions.create_lb && (
            <form className="grid gap-3 md:grid-cols-[1fr_1fr_auto]" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => loadBalancersApi.create({ name: lbName, projectId: currentProject.id, logicalNetworkId: lbNetwork, protocol: "tcp" })); }}>
              <div><Label htmlFor="lb-name">Name</Label><Input id="lb-name" value={lbName} onChange={(e) => setLBName(e.target.value)} required /></div>
              <SelectField id="lb-network" label="VIP network" value={lbNetwork} onChange={setLBNetwork}><option value="">Select a network</option>{(networksQuery.data ?? []).map((network) => <option key={network.id} value={network.id}>{network.name}</option>)}</SelectField>
              <Button className="self-end" disabled={mutation.isPending}>Create</Button>
            </form>
          )}
          <div className="divide-y rounded-lg border">
            {(loadBalancersQuery.data ?? []).map((lb) => (
              <div key={lb.id} className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="font-medium">{lb.name} <span className="font-mono text-sm text-muted-foreground">{lb.vip}</span></p>
                  <p className="text-sm text-muted-foreground">{lb.logicalNetworkName ?? lb.logicalNetworkId} · {lb.protocol.toUpperCase()} · {lb.observedState} · {lb.listeners.length} listeners · {lb.backends.length} backends</p>
                  {lb.lastError && <p className="text-sm text-red-600" role="alert">{lb.lastError}</p>}
                </div>
                <div className="flex gap-2">
                  {resourcePermissions[`lb_update:${lb.id}`] && <Button variant="outline" size="sm" onClick={() => setSelectedLB(selectedLB === lb.id ? "" : lb.id)}>{selectedLB === lb.id ? "Close" : "Manage"}</Button>}
                  {resourcePermissions[`lb_delete:${lb.id}`] && <Button variant="ghost" size="icon" aria-label={`Delete ${lb.name}`} onClick={() => confirmMutation(`Delete load balancer ${lb.name}?`, () => loadBalancersApi.delete(lb.id))}><Trash2 className="h-4 w-4" /></Button>}
                </div>
              </div>
            ))}
            {loadBalancersQuery.data?.length === 0 && <p className="p-4 text-sm text-muted-foreground">No load balancers.</p>}
          </div>
          {managedLB && (
            <div className="grid gap-5 rounded-lg border p-4 lg:grid-cols-2">
              <section className="space-y-3">
                <h3 className="font-medium">Listeners</h3>
                <form className="grid grid-cols-[1fr_1fr_auto] gap-2" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => loadBalancersApi.addListener(managedLB.id, Number(listenerPort), Number(backendPort))); }}>
                  <div><Label htmlFor="listener-port">VIP port</Label><Input id="listener-port" type="number" min="1" max="65535" value={listenerPort} onChange={(event) => setListenerPort(event.target.value)} required /></div>
                  <div><Label htmlFor="backend-port">Backend port</Label><Input id="backend-port" type="number" min="1" max="65535" value={backendPort} onChange={(event) => setBackendPort(event.target.value)} required /></div>
                  <Button className="self-end">Add</Button>
                </form>
                <div className="divide-y">{managedLB.listeners.map((listener) => <div key={listener.id} className="flex items-center justify-between py-2 text-sm"><span>:{listener.port} → :{listener.backendPort}</span><Button variant="ghost" size="icon" aria-label={`Delete listener on port ${listener.port}`} onClick={() => confirmMutation(`Delete listener on port ${listener.port}?`, () => loadBalancersApi.deleteListener(managedLB.id, listener.id))}><Trash2 className="h-4 w-4" /></Button></div>)}</div>
              </section>
              <section className="space-y-3">
                <h3 className="font-medium">Backends</h3>
                <form className="flex items-end gap-2" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => loadBalancersApi.addBackend(managedLB.id, { ipAddress: backendIP })); }}>
                  <div className="flex-1"><Label htmlFor="backend-ip">IPv4 address</Label><Input id="backend-ip" inputMode="decimal" value={backendIP} onChange={(event) => setBackendIP(event.target.value)} placeholder="10.0.0.25" required /></div>
                  <Button>Add</Button>
                </form>
                <div className="divide-y">{managedLB.backends.map((backend) => <div key={backend.id} className="flex items-center justify-between py-2 text-sm"><span className="font-mono">{backend.ipAddress ?? backend.vmId ?? "Unavailable"} · {backend.healthStatus}</span><Button variant="ghost" size="icon" aria-label={`Delete backend ${backend.ipAddress ?? backend.id}`} onClick={() => confirmMutation(`Delete backend ${backend.ipAddress ?? backend.id}?`, () => loadBalancersApi.deleteBackend(managedLB.id, backend.id))}><Trash2 className="h-4 w-4" /></Button></div>)}</div>
              </section>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><Globe2 className="h-5 w-5" />Floating IPs</CardTitle></CardHeader>
        <CardContent className="space-y-5">
          {user?.isSystemAdmin && currentOrg && (
            <form className="grid gap-3 md:grid-cols-5" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => floatingIPsApi.createPool({ name: poolName, cidr: poolCIDR, gateway: poolGateway || undefined, siteId: poolSite, organizationId: currentOrg.id })); }}>
              <div><Label htmlFor="pool-name">Pool name</Label><Input id="pool-name" value={poolName} onChange={(e) => setPoolName(e.target.value)} required /></div>
              <div><Label htmlFor="pool-cidr">CIDR</Label><Input id="pool-cidr" value={poolCIDR} onChange={(e) => setPoolCIDR(e.target.value)} placeholder="203.0.113.0/24" required /></div>
              <div><Label htmlFor="pool-gateway">Gateway</Label><Input id="pool-gateway" value={poolGateway} onChange={(e) => setPoolGateway(e.target.value)} /></div>
              <SelectField id="pool-site" label="Site" value={poolSite} onChange={setPoolSite}><option value="">Select a site</option>{(sitesQuery.data ?? []).map((site) => <option key={site.id} value={site.id}>{site.name}</option>)}</SelectField>
              <Button className="self-end">Create pool</Button>
            </form>
          )}
          {permissions.allocate_ip && <form className="flex items-end gap-3" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => floatingIPsApi.allocate({ poolId: allocationPool, projectId: currentProject.id })); }}><div className="min-w-64"><SelectField id="allocation-pool" label="Address pool" value={allocationPool} onChange={setAllocationPool}><option value="">Select a pool</option>{(poolsQuery.data ?? []).map((pool) => <option key={pool.id} value={pool.id}>{pool.name} ({pool.cidr})</option>)}</SelectField></div><Button>Allocate address</Button></form>}
          <div className="divide-y rounded-lg border">
            {(floatingIPsQuery.data ?? []).map((address) => (
              <div key={address.id} className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between">
                <div><p className="font-mono font-medium">{address.address}</p><p className="text-sm text-muted-foreground">{address.vmId ? `Attached to ${projectVMs.find((vm) => vm.id === address.vmId)?.name ?? address.vmId}` : "Reserved, not attached"}</p></div>
                <div className="flex items-end gap-2">
                  {!address.vmId && resourcePermissions[`ip_attach:${address.id}`] && <><div><Label className="sr-only" htmlFor={`floating-vm-${address.id}`}>VM for {address.address}</Label><select id={`floating-vm-${address.id}`} value={floatingVMs[address.id] ?? ""} onChange={(event) => setFloatingVMs((current) => ({ ...current, [address.id]: event.target.value }))} className="h-9 rounded-md border border-input bg-background px-3 text-sm"><option value="">Select VM</option>{projectVMs.map((vm) => <option key={vm.id} value={vm.id}>{vm.name}</option>)}</select></div><Button size="sm" disabled={!floatingVMs[address.id]} onClick={() => mutation.mutate(() => floatingIPsApi.attach(address.id, floatingVMs[address.id]))}>Attach</Button></>}
                  {address.vmId && resourcePermissions[`ip_detach:${address.id}`] && <Button variant="outline" size="sm" onClick={() => mutation.mutate(() => floatingIPsApi.detach(address.id))}>Detach</Button>}
                  {resourcePermissions[`ip_release:${address.id}`] && <Button variant="ghost" size="icon" aria-label={`Release ${address.address}`} disabled={!!address.vmId} onClick={() => confirmMutation(`Release floating IP ${address.address}?`, () => floatingIPsApi.release(address.id))}><Trash2 className="h-4 w-4" /></Button>}
                </div>
              </div>
            ))}
            {floatingIPsQuery.data?.length === 0 && <p className="p-4 text-sm text-muted-foreground">No floating IPs allocated.</p>}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><Network className="h-5 w-5" />DNS zones and records</CardTitle></CardHeader>
        <CardContent className="space-y-5">
          {permissions.create_zone && <form className="flex items-end gap-3" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => dnsApi.createZone({ name: zoneName, projectId: currentProject.id })); }}><div className="min-w-72"><Label htmlFor="zone-name">Zone name</Label><Input id="zone-name" value={zoneName} onChange={(e) => setZoneName(e.target.value)} placeholder="acme.internal" required /></div><Button>Create zone</Button></form>}
          <div className="divide-y rounded-lg border">
            {(zonesQuery.data ?? []).map((zone) => <div key={zone.id} className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"><div><p className="font-medium">{zone.name}</p><p className="text-sm text-muted-foreground">{zone.recordCount} authored records · {zone.networks.length} attached networks</p></div><div className="flex gap-2"><Button variant="outline" size="sm" onClick={() => setRecordZone(recordZone === zone.id ? "" : zone.id)}>{recordZone === zone.id ? "Close" : "Manage"}</Button>{resourcePermissions[`zone_delete:${zone.id}`] && <Button variant="ghost" size="icon" aria-label={`Delete ${zone.name}`} onClick={() => confirmMutation(`Delete DNS zone ${zone.name} and its records?`, () => dnsApi.deleteZone(zone.id))}><Trash2 className="h-4 w-4" /></Button>}</div></div>)}
            {zonesQuery.data?.length === 0 && <p className="p-4 text-sm text-muted-foreground">No DNS zones.</p>}
          </div>
          {recordZone && (() => {
            const zone = (zonesQuery.data ?? []).find((item) => item.id === recordZone);
            if (!zone) return null;
            return <div className="space-y-5 rounded-lg border p-4">
              <h3 className="font-medium">Manage {zone.name}</h3>
              {resourcePermissions[`zone_create:${zone.id}`] && <form className="grid gap-3 md:grid-cols-[1fr_100px_2fr_100px]" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => dnsApi.createRecord(recordZone, { name: recordName, type: recordType, value: recordValue, ttl: 300 })); }}><div><Label htmlFor="record-name">Name</Label><Input id="record-name" value={recordName} onChange={(e) => setRecordName(e.target.value)} /></div><SelectField id="record-type" label="Type" value={recordType} onChange={(value) => setRecordType(value as CreateDNSRecordRequest["type"])}>{["A", "AAAA", "CNAME", "TXT", "SRV", "PTR"].map((type) => <option key={type}>{type}</option>)}</SelectField><div><Label htmlFor="record-value">Value</Label><Input id="record-value" value={recordValue} onChange={(e) => setRecordValue(e.target.value)} required /></div><Button className="self-end">Add record</Button></form>}
              <div className="divide-y">{(recordsQuery.data ?? []).map((record) => <div key={record.id} className="flex items-center justify-between py-2"><code className="overflow-x-auto text-sm">{record.name} {record.ttl} {record.type} {record.value}</code>{resourcePermissions[`record_delete:${record.id}`] && <Button variant="ghost" size="icon" aria-label={`Delete ${record.fqdn} ${record.type}`} onClick={() => confirmMutation(`Delete ${record.fqdn} ${record.type}?`, () => dnsApi.deleteRecord(recordZone, record.id))}><Trash2 className="h-4 w-4" /></Button>}</div>)}</div>
              {resourcePermissions[`zone_attach:${zone.id}`] && <form className="flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => dnsApi.attachNetwork(zone.id, zoneNetwork, zonePrimary)); }}><div className="min-w-64"><SelectField id="zone-network" label="Attach network" value={zoneNetwork} onChange={setZoneNetwork}><option value="">Select a network</option>{(networksQuery.data ?? []).filter((network) => !zone.networks.some((attachment) => attachment.networkId === network.id)).map((network) => <option key={network.id} value={network.id}>{network.name}</option>)}</SelectField></div><label className="flex h-9 items-center gap-2 text-sm"><input type="checkbox" checked={zonePrimary} onChange={(event) => setZonePrimary(event.target.checked)} />Primary zone</label><Button disabled={!zoneNetwork}>Attach</Button></form>}
              <div className="flex flex-wrap gap-2">{zone.networks.map((attachment) => <div key={attachment.networkId} className="flex items-center gap-2 rounded-md border px-3 py-1.5 text-sm"><span>{attachment.networkName ?? attachment.networkId}{attachment.isPrimary ? " · primary" : ""}</span>{resourcePermissions[`zone_detach:${zone.id}`] && !attachment.isPrimary && <Button variant="ghost" size="sm" onClick={() => confirmMutation(`Detach ${zone.name} from ${attachment.networkName}?`, () => dnsApi.detachNetwork(zone.id, attachment.networkId))}>Detach</Button>}</div>)}</div>
            </div>;
          })()}
        </CardContent>
      </Card>
    </div>
  );
}
