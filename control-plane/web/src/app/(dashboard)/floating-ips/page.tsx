"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Globe2, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { SelectField } from "@/components/networking/select-field";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { floatingIPsApi } from "@/lib/api/platform-services";
import { usePermissions, useSites, useVMs } from "@/lib/hooks";
import { useAuth, useOrganization, useProjectContext } from "@/providers";

export default function FloatingIPsPage() {
  const { currentProject } = useProjectContext();
  const { currentOrg } = useOrganization();
  const { user } = useAuth();
  const projectId = currentProject?.id;
  const queryClient = useQueryClient();
  const sitesQuery = useSites();
  const vmsQuery = useVMs();

  const [poolName, setPoolName] = useState("");
  const [poolCIDR, setPoolCIDR] = useState("");
  const [poolGateway, setPoolGateway] = useState("");
  const [poolSite, setPoolSite] = useState("");
  const [allocationPool, setAllocationPool] = useState("");
  const [selectedVMs, setSelectedVMs] = useState<Record<string, string>>({});

  const { permissions } = usePermissions(
    projectId
      ? [
          {
            key: "allocate",
            action: "floatingip:create",
            node: { type: "project", id: projectId },
          },
        ]
      : []
  );
  const poolsQuery = useQuery({
    queryKey: ["floating-ip-pools"],
    queryFn: ({ signal }) => floatingIPsApi.listPools(signal),
  });
  const floatingIPsQuery = useQuery({
    queryKey: ["floating-ips", { projectId }],
    queryFn: ({ signal }) => floatingIPsApi.list(projectId!, signal),
    enabled: !!projectId,
  });
  const { permissions: resourcePermissions } = usePermissions(
    (floatingIPsQuery.data ?? []).flatMap((address) => [
      {
        key: `attach:${address.id}`,
        action: "floatingip:attach",
        node: { type: "floating_ip", id: address.id },
      },
      {
        key: `detach:${address.id}`,
        action: "floatingip:detach",
        node: { type: "floating_ip", id: address.id },
      },
      {
        key: `release:${address.id}`,
        action: "floatingip:release",
        node: { type: "floating_ip", id: address.id },
      },
    ])
  );

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["floating-ip-pools"] });
    void queryClient.invalidateQueries({ queryKey: ["floating-ips"] });
  };
  const mutation = useMutation({
    mutationFn: (work: () => Promise<unknown>) => work(),
    onSuccess: () => {
      refresh();
      toast.success("Floating IP updated");
    },
    onError: (error) => toast.error(error.message),
  });
  const confirmMutation = (message: string, work: () => Promise<unknown>) => {
    if (window.confirm(message)) mutation.mutate(work);
  };

  if (!currentProject) {
    return (
      <p className="py-12 text-center text-muted-foreground">
        Select a project first.
      </p>
    );
  }

  const floatingIPs = floatingIPsQuery.data ?? [];
  const projectVMs = (vmsQuery.data ?? []).filter(
    (vm) => vm.projectId === currentProject.id
  );
  const error =
    floatingIPsQuery.error ??
    poolsQuery.error ??
    sitesQuery.error ??
    vmsQuery.error;

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div className="flex items-center gap-3">
        <Globe2 className="h-8 w-8 text-blue-600" />
        <div>
          <h1 className="text-2xl font-semibold">Floating IPs</h1>
          <p className="text-muted-foreground">
            Manage public addresses for {currentProject.name}
          </p>
        </div>
      </div>

      <QueryErrorNotice
        resource="floating IPs"
        error={error}
        hasData={floatingIPsQuery.data !== undefined}
        onRetry={refresh}
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-lg font-semibold">
            {currentProject.name} Floating IPs ({floatingIPs.length})
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-5">
          {user?.isSystemAdmin && currentOrg && (
            <form
              className="grid gap-3 md:grid-cols-5"
              onSubmit={(event) => {
                event.preventDefault();
                mutation.mutate(() =>
                  floatingIPsApi.createPool({
                    name: poolName,
                    cidr: poolCIDR,
                    gateway: poolGateway || undefined,
                    siteId: poolSite,
                    organizationId: currentOrg.id,
                  })
                );
              }}
            >
              <div>
                <Label htmlFor="pool-name">Pool name</Label>
                <Input
                  id="pool-name"
                  value={poolName}
                  onChange={(event) => setPoolName(event.target.value)}
                  required
                />
              </div>
              <div>
                <Label htmlFor="pool-cidr">CIDR</Label>
                <Input
                  id="pool-cidr"
                  value={poolCIDR}
                  onChange={(event) => setPoolCIDR(event.target.value)}
                  placeholder="203.0.113.0/24"
                  required
                />
              </div>
              <div>
                <Label htmlFor="pool-gateway">Gateway</Label>
                <Input
                  id="pool-gateway"
                  value={poolGateway}
                  onChange={(event) => setPoolGateway(event.target.value)}
                />
              </div>
              <SelectField
                id="pool-site"
                label="Site"
                value={poolSite}
                onChange={setPoolSite}
              >
                <option value="">Select a site</option>
                {(sitesQuery.data ?? []).map((site) => (
                  <option key={site.id} value={site.id}>
                    {site.name}
                  </option>
                ))}
              </SelectField>
              <Button className="self-end" disabled={mutation.isPending}>
                Create pool
              </Button>
            </form>
          )}

          {permissions.allocate && (
            <form
              className="flex items-end gap-3"
              onSubmit={(event) => {
                event.preventDefault();
                mutation.mutate(() =>
                  floatingIPsApi.allocate({
                    poolId: allocationPool,
                    projectId: currentProject.id,
                  })
                );
              }}
            >
              <div className="min-w-64">
                <SelectField
                  id="allocation-pool"
                  label="Address pool"
                  value={allocationPool}
                  onChange={setAllocationPool}
                >
                  <option value="">Select a pool</option>
                  {(poolsQuery.data ?? []).map((pool) => (
                    <option key={pool.id} value={pool.id}>
                      {pool.name} ({pool.cidr})
                    </option>
                  ))}
                </SelectField>
              </div>
              <Button disabled={mutation.isPending}>Allocate address</Button>
            </form>
          )}

          <div className="divide-y rounded-lg border">
            {floatingIPs.map((address) => (
              <div
                key={address.id}
                className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p className="font-mono font-medium">{address.address}</p>
                  <p className="text-sm text-muted-foreground">
                    {address.vmId
                      ? `Attached to ${
                          projectVMs.find((vm) => vm.id === address.vmId)?.name ??
                          address.vmId
                        }`
                      : "Reserved, not attached"}
                  </p>
                </div>
                <div className="flex items-end gap-2">
                  {!address.vmId &&
                    resourcePermissions[`attach:${address.id}`] && (
                      <>
                        <div>
                          <Label
                            className="sr-only"
                            htmlFor={`floating-vm-${address.id}`}
                          >
                            VM for {address.address}
                          </Label>
                          <select
                            id={`floating-vm-${address.id}`}
                            value={selectedVMs[address.id] ?? ""}
                            onChange={(event) =>
                              setSelectedVMs((current) => ({
                                ...current,
                                [address.id]: event.target.value,
                              }))
                            }
                            className="h-9 rounded-md border border-input bg-background px-3 text-sm"
                          >
                            <option value="">Select VM</option>
                            {projectVMs.map((vm) => (
                              <option key={vm.id} value={vm.id}>
                                {vm.name}
                              </option>
                            ))}
                          </select>
                        </div>
                        <Button
                          size="sm"
                          disabled={!selectedVMs[address.id] || mutation.isPending}
                          onClick={() =>
                            mutation.mutate(() =>
                              floatingIPsApi.attach(
                                address.id,
                                selectedVMs[address.id]
                              )
                            )
                          }
                        >
                          Attach
                        </Button>
                      </>
                    )}
                  {address.vmId &&
                    resourcePermissions[`detach:${address.id}`] && (
                      <Button
                        variant="outline"
                        size="sm"
                        disabled={mutation.isPending}
                        onClick={() =>
                          mutation.mutate(() => floatingIPsApi.detach(address.id))
                        }
                      >
                        Detach
                      </Button>
                    )}
                  {resourcePermissions[`release:${address.id}`] && (
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Release ${address.address}`}
                      disabled={!!address.vmId || mutation.isPending}
                      onClick={() =>
                        confirmMutation(
                          `Release floating IP ${address.address}?`,
                          () => floatingIPsApi.release(address.id)
                        )
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
            {floatingIPsQuery.data?.length === 0 && (
              <p className="p-4 text-sm text-muted-foreground">
                No floating IPs allocated.
              </p>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
