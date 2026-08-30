"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Network, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { SelectField } from "@/components/networking/select-field";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import {
  dnsApi,
  type CreateDNSRecordRequest,
} from "@/lib/api/platform-services";
import { useNetworks, usePermissions } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function DNSZonesPage() {
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const queryClient = useQueryClient();
  const networksQuery = useNetworks(projectId);

  const [zoneName, setZoneName] = useState("");
  const [selectedZoneId, setSelectedZoneId] = useState("");
  const [recordName, setRecordName] = useState("@");
  const [recordType, setRecordType] =
    useState<CreateDNSRecordRequest["type"]>("A");
  const [recordValue, setRecordValue] = useState("");
  const [networkId, setNetworkId] = useState("");
  const [isPrimary, setIsPrimary] = useState(false);

  const { permissions } = usePermissions(
    projectId
      ? [
          {
            key: "create",
            action: "dns:create",
            node: { type: "project", id: projectId },
          },
        ]
      : []
  );
  const zonesQuery = useQuery({
    queryKey: ["dns-zones", { projectId }],
    queryFn: ({ signal }) => dnsApi.listZones(projectId!, signal),
    enabled: !!projectId,
  });
  const recordsQuery = useQuery({
    queryKey: ["dns-records", { zoneId: selectedZoneId }],
    queryFn: ({ signal }) => dnsApi.listRecords(selectedZoneId, signal),
    enabled: !!selectedZoneId,
  });
  const { permissions: resourcePermissions } = usePermissions([
    ...(zonesQuery.data ?? []).flatMap((zone) => [
      {
        key: `create:${zone.id}`,
        action: "dns:create",
        node: { type: "dns_zone" as const, id: zone.id },
      },
      {
        key: `attach:${zone.id}`,
        action: "dns:attach",
        node: { type: "dns_zone" as const, id: zone.id },
      },
      {
        key: `detach:${zone.id}`,
        action: "dns:detach",
        node: { type: "dns_zone" as const, id: zone.id },
      },
      {
        key: `delete:${zone.id}`,
        action: "dns:delete",
        node: { type: "dns_zone" as const, id: zone.id },
      },
    ]),
    ...(recordsQuery.data ?? []).map((record) => ({
      key: `delete-record:${record.id}`,
      action: "dns:delete",
      node: { type: "dns_record" as const, id: record.id },
    })),
  ]);

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["dns-zones"] });
    void queryClient.invalidateQueries({ queryKey: ["dns-records"] });
  };
  const mutation = useMutation({
    mutationFn: (work: () => Promise<unknown>) => work(),
    onSuccess: () => {
      refresh();
      toast.success("DNS updated");
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

  const zones = zonesQuery.data ?? [];
  const selectedZone = zones.find((zone) => zone.id === selectedZoneId);
  const error = zonesQuery.error ?? recordsQuery.error ?? networksQuery.error;

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div className="flex items-center gap-3">
        <Network className="h-8 w-8 text-blue-600" />
        <div>
          <h1 className="text-2xl font-semibold">DNS zones</h1>
          <p className="text-muted-foreground">
            Manage DNS zones, records, and network attachments for{" "}
            {currentProject.name}
          </p>
        </div>
      </div>

      <QueryErrorNotice
        resource="DNS zones"
        error={error}
        hasData={zonesQuery.data !== undefined}
        onRetry={refresh}
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-lg font-semibold">
            {currentProject.name} DNS Zones ({zones.length})
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-5">
          {permissions.create && (
            <form
              className="flex items-end gap-3"
              onSubmit={(event) => {
                event.preventDefault();
                mutation.mutate(() =>
                  dnsApi.createZone({
                    name: zoneName,
                    projectId: currentProject.id,
                  })
                );
              }}
            >
              <div className="min-w-72">
                <Label htmlFor="zone-name">Zone name</Label>
                <Input
                  id="zone-name"
                  value={zoneName}
                  onChange={(event) => setZoneName(event.target.value)}
                  placeholder="acme.internal"
                  required
                />
              </div>
              <Button disabled={mutation.isPending}>Create zone</Button>
            </form>
          )}

          <div className="divide-y rounded-lg border">
            {zones.map((zone) => (
              <div
                key={zone.id}
                className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p className="font-medium">{zone.name}</p>
                  <p className="text-sm text-muted-foreground">
                    {zone.recordCount} authored records · {zone.networks.length}{" "}
                    attached networks
                  </p>
                </div>
                <div className="flex gap-2">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setSelectedZoneId(
                        selectedZoneId === zone.id ? "" : zone.id
                      )
                    }
                  >
                    {selectedZoneId === zone.id ? "Close" : "Manage"}
                  </Button>
                  {resourcePermissions[`delete:${zone.id}`] && (
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Delete ${zone.name}`}
                      onClick={() =>
                        confirmMutation(
                          `Delete DNS zone ${zone.name} and its records?`,
                          () => dnsApi.deleteZone(zone.id)
                        )
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
            {zonesQuery.data?.length === 0 && (
              <p className="p-4 text-sm text-muted-foreground">No DNS zones.</p>
            )}
          </div>

          {selectedZone && (
            <div className="space-y-5 rounded-lg border p-4">
              <h3 className="font-medium">Manage {selectedZone.name}</h3>

              {resourcePermissions[`create:${selectedZone.id}`] && (
                <form
                  className="grid gap-3 md:grid-cols-[1fr_100px_2fr_100px]"
                  onSubmit={(event) => {
                    event.preventDefault();
                    mutation.mutate(() =>
                      dnsApi.createRecord(selectedZone.id, {
                        name: recordName,
                        type: recordType,
                        value: recordValue,
                        ttl: 300,
                      })
                    );
                  }}
                >
                  <div>
                    <Label htmlFor="record-name">Name</Label>
                    <Input
                      id="record-name"
                      value={recordName}
                      onChange={(event) => setRecordName(event.target.value)}
                    />
                  </div>
                  <SelectField
                    id="record-type"
                    label="Type"
                    value={recordType}
                    onChange={(value) =>
                      setRecordType(value as CreateDNSRecordRequest["type"])
                    }
                  >
                    {["A", "AAAA", "CNAME", "TXT", "SRV", "PTR"].map(
                      (type) => (
                        <option key={type}>{type}</option>
                      )
                    )}
                  </SelectField>
                  <div>
                    <Label htmlFor="record-value">Value</Label>
                    <Input
                      id="record-value"
                      value={recordValue}
                      onChange={(event) => setRecordValue(event.target.value)}
                      required
                    />
                  </div>
                  <Button className="self-end" disabled={mutation.isPending}>
                    Add record
                  </Button>
                </form>
              )}

              <div className="divide-y">
                {(recordsQuery.data ?? []).map((record) => (
                  <div
                    key={record.id}
                    className="flex items-center justify-between py-2"
                  >
                    <code className="overflow-x-auto text-sm">
                      {record.name} {record.ttl} {record.type} {record.value}
                    </code>
                    {resourcePermissions[`delete-record:${record.id}`] && (
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Delete ${record.fqdn} ${record.type}`}
                        onClick={() =>
                          confirmMutation(
                            `Delete ${record.fqdn} ${record.type}?`,
                            () =>
                              dnsApi.deleteRecord(selectedZone.id, record.id)
                          )
                        }
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    )}
                  </div>
                ))}
              </div>

              {resourcePermissions[`attach:${selectedZone.id}`] && (
                <form
                  className="flex flex-col gap-3 sm:flex-row sm:items-end"
                  onSubmit={(event) => {
                    event.preventDefault();
                    mutation.mutate(() =>
                      dnsApi.attachNetwork(
                        selectedZone.id,
                        networkId,
                        isPrimary
                      )
                    );
                  }}
                >
                  <div className="min-w-64">
                    <SelectField
                      id="zone-network"
                      label="Attach network"
                      value={networkId}
                      onChange={setNetworkId}
                    >
                      <option value="">Select a network</option>
                      {(networksQuery.data ?? [])
                        .filter(
                          (network) =>
                            !selectedZone.networks.some(
                              (attachment) =>
                                attachment.networkId === network.id
                            )
                        )
                        .map((network) => (
                          <option key={network.id} value={network.id}>
                            {network.name}
                          </option>
                        ))}
                    </SelectField>
                  </div>
                  <label className="flex h-9 items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={isPrimary}
                      onChange={(event) => setIsPrimary(event.target.checked)}
                    />
                    Primary zone
                  </label>
                  <Button disabled={!networkId || mutation.isPending}>
                    Attach
                  </Button>
                </form>
              )}

              <div className="flex flex-wrap gap-2">
                {selectedZone.networks.map((attachment) => (
                  <div
                    key={attachment.networkId}
                    className="flex items-center gap-2 rounded-md border px-3 py-1.5 text-sm"
                  >
                    <span>
                      {attachment.networkName ?? attachment.networkId}
                      {attachment.isPrimary ? " · primary" : ""}
                    </span>
                    {resourcePermissions[`detach:${selectedZone.id}`] &&
                      !attachment.isPrimary && (
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() =>
                            confirmMutation(
                              `Detach ${selectedZone.name} from ${
                                attachment.networkName ??
                                attachment.networkId
                              }?`,
                              () =>
                                dnsApi.detachNetwork(
                                  selectedZone.id,
                                  attachment.networkId
                                )
                            )
                          }
                        >
                          Detach
                        </Button>
                      )}
                  </div>
                ))}
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
