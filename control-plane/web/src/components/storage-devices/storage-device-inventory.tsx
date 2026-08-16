"use client";

import { useState } from "react";
import type { StorageDevice } from "@/types/api";
import { usePermissions } from "@/lib/hooks/use-permissions";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  formatDeviceSize,
  formatDeviceUses,
  groupStorageDevices,
  osdSelectionWarning,
  storageDeviceStatus,
  type StorageAgentSummary,
  type StorageSiteSummary,
} from "./storage-device-model";

const blockedMessages: Record<NonNullable<StorageDevice["osdEligibilityBlockedReason"]>, string> = {
  missingIdentity: "The device has no stable WWN or serial identity.",
  notPresent: "The device is no longer present on the agent.",
  inUse: "The device is already in use.",
  draining: "The device is draining.",
  faulted: "The device is faulted.",
  agentOffline: "The agent is offline.",
  staleObservation: "The device observation is older than 60 seconds.",
};

interface StorageDeviceInventoryProps {
  devices: StorageDevice[];
  sites: StorageSiteSummary[];
  agents: StorageAgentSummary[];
  selectedSiteId?: string;
  onSiteChange?: (siteId: string | undefined) => void;
  isLoading?: boolean;
  error?: Error | null;
  mutationError?: Error | null;
  mutationPending?: boolean;
  onRetry?: () => void;
  onSetOsdEligibility: (deviceId: string, osdEligible: boolean) => void | Promise<void>;
}

export function StorageDeviceInventory({
  devices,
  sites,
  agents,
  selectedSiteId,
  onSiteChange,
  isLoading = false,
  error,
  mutationError,
  mutationPending = false,
  onRetry,
  onSetOsdEligibility,
}: StorageDeviceInventoryProps) {
  const [confirmation, setConfirmation] = useState<StorageDevice | null>(null);
  const visibleDevices = selectedSiteId
    ? devices.filter((device) => device.siteId === selectedSiteId)
    : devices;
  const groups = groupStorageDevices(visibleDevices, sites, agents);
  const agentIds = [...new Set(visibleDevices.map((device) => device.agentId))];
  const { permissions } = usePermissions(
    agentIds.map((agentId) => ({
      key: `manage:${agentId}`,
      action: "agent:manage",
      node: { type: "agent" as const, id: agentId },
    })),
  );

  function toggle(device: StorageDevice) {
    if (device.osdEligible) {
      void Promise.resolve(onSetOsdEligibility(device.id, false)).catch(() => undefined);
    } else {
      setConfirmation(device);
    }
  }

  async function confirmSelection() {
    if (!confirmation) return;
    try {
      await onSetOsdEligibility(confirmation.id, true);
      setConfirmation(null);
    } catch {
      // The mutation error is rendered from the owning hook without replacing
      // the dialog's safety context.
    }
  }

  return (
    <div className="space-y-4">
      {onSiteChange && (
        <div className="max-w-xs space-y-1.5">
          <label className="text-sm font-medium" htmlFor="storage-site-filter">Site</label>
          <Select
            value={selectedSiteId ?? "all"}
            onValueChange={(value) => onSiteChange(value === "all" ? undefined : value)}
          >
            <SelectTrigger id="storage-site-filter"><SelectValue placeholder="All sites" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All sites</SelectItem>
              {sites.map((site) => <SelectItem key={site.id} value={site.id}>{site.name}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      )}

      {error && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">
          {error.message}
          {onRetry && <Button variant="link" size="sm" onClick={onRetry}>Retry</Button>}
        </div>
      )}
      {mutationError && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">
          {mutationError.message}
        </div>
      )}

      {isLoading ? (
        <div role="status" aria-label="Loading storage devices" className="space-y-3">
          <Skeleton className="h-28 w-full" />
          <Skeleton className="h-28 w-full" />
        </div>
      ) : groups.length === 0 ? (
        <Card><CardContent className="py-12 text-center text-muted-foreground">No storage devices reported.</CardContent></Card>
      ) : groups.map((site) => (
        <section key={site.siteId} aria-labelledby={`site-${site.siteId}`} className="space-y-3">
          <h2 id={`site-${site.siteId}`} className="text-lg font-semibold">{site.siteName}</h2>
          {site.agents.map((agent) => (
            <Card key={agent.agentId}>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">{agent.agentName}</CardTitle>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Device</TableHead>
                      <TableHead>Hardware</TableHead>
                      <TableHead>Observed use</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Last seen</TableHead>
                      <TableHead className="text-right">OSD eligible</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {agent.devices.map((device) => {
                      const canManage = permissions[`manage:${device.agentId}`] ?? false;
                      const disabled = mutationPending || !canManage || (!device.osdEligible && !device.canMarkOsdEligible);
                      const blocker = device.osdEligibilityBlockedReason
                        ? blockedMessages[device.osdEligibilityBlockedReason]
                        : null;
                      return (
                        <TableRow key={device.id}>
                          <TableCell>
                            <div className="font-mono font-medium">{device.devicePath}</div>
                            <div className="text-xs text-muted-foreground">{formatDeviceSize(device.sizeBytes)}</div>
                          </TableCell>
                          <TableCell>
                            <div>{device.model ?? "Unknown model"} · {device.rotational ? "HDD" : "SSD"}</div>
                            <div className="max-w-sm whitespace-normal text-xs text-muted-foreground">
                              Serial {device.serial ?? "—"} · WWN {device.wwn ?? "—"}
                            </div>
                          </TableCell>
                          <TableCell className="max-w-xs whitespace-normal">{formatDeviceUses(device.uses)}</TableCell>
                          <TableCell>
                            <Badge variant={device.present && device.state === "available" ? "secondary" : "outline"}>
                              {storageDeviceStatus(device)}
                            </Badge>
                          </TableCell>
                          <TableCell>{device.lastSeenAt ? new Date(device.lastSeenAt).toLocaleString() : "Never"}</TableCell>
                          <TableCell>
                            <div className="flex min-w-48 flex-col items-end gap-1 text-right">
                              <Switch
                                checked={device.osdEligible}
                                disabled={disabled}
                                aria-label={`OSD eligibility for ${device.devicePath}`}
                                onClick={() => toggle(device)}
                              />
                              {!canManage ? (
                                <span className="text-xs text-muted-foreground">Read-only access</span>
                              ) : blocker ? (
                                <span className="max-w-64 whitespace-normal text-xs text-muted-foreground">{blocker}</span>
                              ) : (
                                <span className="text-xs text-muted-foreground">{device.osdEligible ? "Selected" : "Available for selection"}</span>
                              )}
                            </div>
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          ))}
        </section>
      ))}

      <Dialog open={confirmation !== null} onOpenChange={(open) => !open && setConfirmation(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Mark this disk OSD-eligible?</DialogTitle>
            <DialogDescription>{osdSelectionWarning}</DialogDescription>
          </DialogHeader>
          {confirmation && <p className="font-mono text-sm">{confirmation.devicePath}</p>}
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmation(null)}>Cancel</Button>
            <Button onClick={() => void confirmSelection()} disabled={mutationPending}>Mark OSD-eligible</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
