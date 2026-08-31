"use client";

import { confirmAction } from "@/providers/confirmation-provider";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Scale, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { SelectField } from "@/components/networking/select-field";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { loadBalancersApi } from "@/lib/api/platform-services";
import { useNetworks, usePermissions } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function LoadBalancersPage() {
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const queryClient = useQueryClient();
  const networksQuery = useNetworks(projectId);

  const [name, setName] = useState("");
  const [networkId, setNetworkId] = useState("");
  const [selectedId, setSelectedId] = useState("");
  const [listenerPort, setListenerPort] = useState("443");
  const [backendPort, setBackendPort] = useState("443");
  const [backendIP, setBackendIP] = useState("");

  const { permissions } = usePermissions(
    projectId
      ? [
          {
            key: "create",
            action: "loadbalancer:create",
            node: { type: "project", id: projectId },
          },
        ]
      : []
  );
  const loadBalancersQuery = useQuery({
    queryKey: ["load-balancers", { projectId }],
    queryFn: ({ signal }) => loadBalancersApi.list(projectId!, signal),
    enabled: !!projectId,
    refetchInterval: 10_000,
  });
  const { permissions: resourcePermissions } = usePermissions(
    (loadBalancersQuery.data ?? []).flatMap((loadBalancer) => [
      {
        key: `update:${loadBalancer.id}`,
        action: "loadbalancer:update",
        node: { type: "load_balancer", id: loadBalancer.id },
      },
      {
        key: `delete:${loadBalancer.id}`,
        action: "loadbalancer:delete",
        node: { type: "load_balancer", id: loadBalancer.id },
      },
    ])
  );

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["load-balancers"] });
  };
  const mutation = useMutation({
    mutationFn: (work: () => Promise<unknown>) => work(),
    onSuccess: () => {
      refresh();
      toast.success("Load balancer updated");
    },
    onError: (error) => toast.error(error.message),
  });
  const confirmMutation = async (message: string, work: () => Promise<unknown>) => {
    if (await confirmAction(message)) mutation.mutate(work);
  };

  if (!currentProject) {
    return (
      <p className="py-12 text-center text-muted-foreground">
        Select a project first.
      </p>
    );
  }

  const loadBalancers = loadBalancersQuery.data ?? [];
  const managedLoadBalancer = loadBalancers.find(
    (loadBalancer) => loadBalancer.id === selectedId
  );
  const error = loadBalancersQuery.error ?? networksQuery.error;

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div className="flex items-center gap-3">
        <Scale className="h-8 w-8 text-blue-600" />
        <div>
          <h1 className="text-2xl font-semibold">Load balancers</h1>
          <p className="text-muted-foreground">
            Distribute traffic across services in {currentProject.name}
          </p>
        </div>
      </div>

      <QueryErrorNotice
        resource="load balancers"
        error={error}
        hasData={loadBalancersQuery.data !== undefined}
        onRetry={refresh}
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-lg font-semibold">
            {currentProject.name} Load Balancers ({loadBalancers.length})
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          {permissions.create && (
            <form
              className="grid gap-3 md:grid-cols-[1fr_1fr_auto]"
              onSubmit={(event) => {
                event.preventDefault();
                mutation.mutate(() =>
                  loadBalancersApi.create({
                    name,
                    projectId: currentProject.id,
                    logicalNetworkId: networkId,
                    protocol: "tcp",
                  })
                );
              }}
            >
              <div>
                <Label htmlFor="lb-name">Name</Label>
                <Input
                  id="lb-name"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  required
                />
              </div>
              <SelectField
                id="lb-network"
                label="VIP network"
                value={networkId}
                onChange={setNetworkId}
              >
                <option value="">Select a network</option>
                {(networksQuery.data ?? []).map((network) => (
                  <option key={network.id} value={network.id}>
                    {network.name}
                  </option>
                ))}
              </SelectField>
              <Button className="self-end" disabled={mutation.isPending}>
                Create
              </Button>
            </form>
          )}

          <div className="divide-y rounded-lg border">
            {loadBalancers.map((loadBalancer) => (
              <div
                key={loadBalancer.id}
                className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p className="font-medium">
                    {loadBalancer.name}{" "}
                    <span className="font-mono text-sm text-muted-foreground">
                      {loadBalancer.vip}
                    </span>
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {loadBalancer.logicalNetworkName ??
                      loadBalancer.logicalNetworkId}{" "}
                    · {loadBalancer.protocol.toUpperCase()} ·{" "}
                    {loadBalancer.observedState} · {loadBalancer.listeners.length}{" "}
                    listeners · {loadBalancer.backends.length} backends
                  </p>
                  {loadBalancer.lastError && (
                    <p className="text-sm text-red-600" role="alert">
                      {loadBalancer.lastError}
                    </p>
                  )}
                </div>
                <div className="flex gap-2">
                  {resourcePermissions[`update:${loadBalancer.id}`] && (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() =>
                        setSelectedId(
                          selectedId === loadBalancer.id ? "" : loadBalancer.id
                        )
                      }
                    >
                      {selectedId === loadBalancer.id ? "Close" : "Manage"}
                    </Button>
                  )}
                  {resourcePermissions[`delete:${loadBalancer.id}`] && (
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Delete ${loadBalancer.name}`}
                      onClick={() =>
                        confirmMutation(
                          `Delete load balancer ${loadBalancer.name}?`,
                          () => loadBalancersApi.delete(loadBalancer.id)
                        )
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
            {loadBalancersQuery.data?.length === 0 && (
              <p className="p-4 text-sm text-muted-foreground">
                No load balancers.
              </p>
            )}
          </div>

          {managedLoadBalancer && (
            <div className="grid gap-5 rounded-lg border p-4 lg:grid-cols-2">
              <section className="space-y-3">
                <h3 className="font-medium">Listeners</h3>
                <form
                  className="grid grid-cols-[1fr_1fr_auto] gap-2"
                  onSubmit={(event) => {
                    event.preventDefault();
                    mutation.mutate(() =>
                      loadBalancersApi.addListener(
                        managedLoadBalancer.id,
                        Number(listenerPort),
                        Number(backendPort)
                      )
                    );
                  }}
                >
                  <div>
                    <Label htmlFor="listener-port">VIP port</Label>
                    <Input
                      id="listener-port"
                      type="number"
                      min="1"
                      max="65535"
                      value={listenerPort}
                      onChange={(event) => setListenerPort(event.target.value)}
                      required
                    />
                  </div>
                  <div>
                    <Label htmlFor="backend-port">Backend port</Label>
                    <Input
                      id="backend-port"
                      type="number"
                      min="1"
                      max="65535"
                      value={backendPort}
                      onChange={(event) => setBackendPort(event.target.value)}
                      required
                    />
                  </div>
                  <Button className="self-end">Add</Button>
                </form>
                <div className="divide-y">
                  {managedLoadBalancer.listeners.map((listener) => (
                    <div
                      key={listener.id}
                      className="flex items-center justify-between py-2 text-sm"
                    >
                      <span>
                        :{listener.port} → :{listener.backendPort}
                      </span>
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Delete listener on port ${listener.port}`}
                        onClick={() =>
                          confirmMutation(
                            `Delete listener on port ${listener.port}?`,
                            () =>
                              loadBalancersApi.deleteListener(
                                managedLoadBalancer.id,
                                listener.id
                              )
                          )
                        }
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  ))}
                </div>
              </section>

              <section className="space-y-3">
                <h3 className="font-medium">Backends</h3>
                <form
                  className="flex items-end gap-2"
                  onSubmit={(event) => {
                    event.preventDefault();
                    mutation.mutate(() =>
                      loadBalancersApi.addBackend(managedLoadBalancer.id, {
                        ipAddress: backendIP,
                      })
                    );
                  }}
                >
                  <div className="flex-1">
                    <Label htmlFor="backend-ip">IPv4 address</Label>
                    <Input
                      id="backend-ip"
                      inputMode="decimal"
                      value={backendIP}
                      onChange={(event) => setBackendIP(event.target.value)}
                      placeholder="10.0.0.25"
                      required
                    />
                  </div>
                  <Button>Add</Button>
                </form>
                <div className="divide-y">
                  {managedLoadBalancer.backends.map((backend) => (
                    <div
                      key={backend.id}
                      className="flex items-center justify-between py-2 text-sm"
                    >
                      <span className="font-mono">
                        {backend.ipAddress ?? backend.vmId ?? "Unavailable"} ·{" "}
                        {backend.healthStatus}
                      </span>
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Delete backend ${
                          backend.ipAddress ?? backend.id
                        }`}
                        onClick={() =>
                          confirmMutation(
                            `Delete backend ${backend.ipAddress ?? backend.id}?`,
                            () =>
                              loadBalancersApi.deleteBackend(
                                managedLoadBalancer.id,
                                backend.id
                              )
                          )
                        }
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  ))}
                </div>
              </section>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
