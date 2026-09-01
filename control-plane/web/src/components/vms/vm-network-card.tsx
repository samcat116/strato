"use client";

import { useState } from "react";
import Link from "next/link";
import { AlertTriangle, Loader2, Plus, RotateCcw, Trash2 } from "lucide-react";
import { toast } from "sonner";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  NicSecurityGroupMenu,
  NicSecurityGroupNames,
} from "@/components/security-groups/nic-security-groups";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { useNetworks } from "@/lib/hooks/use-networks";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { usePendingMutation } from "@/lib/stores/mutations-store";
import { vmsApi } from "@/lib/api/vms";
import {
  MAX_SECURITY_GROUPS_PER_NIC,
  type VM,
  type VMNetworkInterface,
} from "@/types/api";

/** All addresses of a NIC as `address/prefix`. */
function nicAddresses(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).map((a) => `${a.address}/${a.prefixLength}`);
}

/**
 * Guest-reported addresses (qga), as `address/prefix` — or just `address` when
 * the guest agent didn't supply a prefix length (issue #563).
 */
function nicObservedAddresses(nic: VMNetworkInterface): string[] {
  return (nic.observedAddresses ?? []).map((a) =>
    a.prefixLength != null ? `${a.address}/${a.prefixLength}` : a.address,
  );
}

function nicGateways(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).flatMap((a) => (a.gateway ? [a.gateway] : []));
}

export function VMNetworkCard({ vm }: { vm: VM }) {
  const interfaces = vm.networkInterfaces ?? [];
  const [showAttach, setShowAttach] = useState(false);
  const [detachNIC, setDetachNIC] = useState<VMNetworkInterface | null>(null);
  const [networkId, setNetworkId] = useState("");
  const [mtu, setMTU] = useState("");
  const [attachSecurityGroupIds, setAttachSecurityGroupIds] = useState<string[]>(
    [],
  );
  const { isLoading: isSubmitting, busyKey, run } = useAcceptedMutation();
  const pendingMutation = usePendingMutation(vm.id);
  const mutationPending = isSubmitting || !!pendingMutation;
  const { data: networks = [] } = useNetworks(vm.projectId);
  const {
    data: securityGroups = [],
    isError: securityGroupsFailed,
  } = useSecurityGroups(vm.projectId);
  const showSecurityGroups = securityGroups.length > 0;

  const resetAttach = () => {
    setShowAttach(false);
    setNetworkId("");
    setMTU("");
    setAttachSecurityGroupIds([]);
  };

  const attach = () => {
    if (!networkId) return;
    const parsedMTU = mtu ? Number(mtu) : undefined;
    if (
      parsedMTU != null &&
      (!Number.isInteger(parsedMTU) || parsedMTU < 68 || parsedMTU > 65535)
    ) {
      toast.error("MTU must be a whole number from 68 to 65535");
      return;
    }
    const payload = {
      networkId,
      mtu: parsedMTU,
      securityGroupIds:
        attachSecurityGroupIds.length > 0
          ? attachSecurityGroupIds
          : undefined,
    };
    void run({
      busyKey: "attach",
      intentKey: JSON.stringify(["POST", `/api/vms/${vm.id}/interfaces`, payload]),
      request: (idempotencyKey) =>
        vmsApi.attachInterface(vm.id, payload, idempotencyKey),
      watch: {
        kind: "attach",
        resourceKind: "virtual_machine",
        resourceName: vm.name,
      },
      errorMessage: "Failed to attach network interface",
      successMessage: "Attaching network interface",
      onSuccess: resetAttach,
    });
  };

  const detach = (nic: VMNetworkInterface) => {
    if (!nic.id) return;
    void run({
      busyKey: nic.id,
      intentKey: JSON.stringify(["DELETE", `/api/vms/${vm.id}/interfaces/${nic.id}`, null]),
      request: (idempotencyKey) =>
        vmsApi.detachInterface(vm.id, nic.id!, idempotencyKey),
      watch: {
        kind: "detach",
        resourceKind: "virtual_machine",
        resourceName: vm.name,
      },
      errorMessage: "Failed to detach network interface",
      successMessage: `Detaching ${nic.deviceName}`,
      onSuccess: () => setDetachNIC(null),
    });
  };

  const retry = (nic: VMNetworkInterface) => {
    if (!nic.id) return;
    const retryingDetach = nic.attachmentState === "detach_failed";
    void run({
      busyKey: nic.id,
      intentKey: JSON.stringify(["POST", `/api/vms/${vm.id}/interfaces/${nic.id}/retry`, null]),
      request: (idempotencyKey) =>
        vmsApi.retryInterface(vm.id, nic.id!, idempotencyKey),
      watch: {
        kind: retryingDetach ? "detach" : "attach",
        resourceKind: "virtual_machine",
        resourceName: vm.name,
      },
      errorMessage: "Failed to retry network interface mutation",
      successMessage: `Retrying ${nic.deviceName}`,
    });
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader>
          <div className="flex items-center justify-between gap-3">
            <CardTitle className="text-lg font-semibold text-foreground">
              Network Interfaces
            </CardTitle>
            <Button
              size="sm"
              variant="outline"
              onClick={() => setShowAttach(true)}
              disabled={
                mutationPending ||
                interfaces.length >= 8 ||
                vm.hypervisorType === "firecracker"
              }
              title={
                vm.hypervisorType === "firecracker"
                  ? "Firecracker network interfaces are fixed at creation"
                  : undefined
              }
            >
              <Plus className="mr-1 h-4 w-4" /> Attach
            </Button>
          </div>
          {(vm.observedHostname || vm.qgaAvailable != null) && (
            <p className="text-sm text-muted-foreground">
              {vm.observedHostname ? (
                <>
                  Guest hostname:{" "}
                  <span className="font-mono text-foreground/80">
                    {vm.observedHostname}
                  </span>
                </>
              ) : (
                "Guest agent connected"
              )}
            </p>
          )}
        </CardHeader>
        <CardContent>
        {vm.securityGroupsEnforced === false && (
          // Not a nicety: without this the UI shows attached groups on a host
          // that ignores them entirely, which reads as "filtered" when it
          // isn't. Derived server-side — listing agents is admin-only, so a
          // project user could never work this out from the agent's version.
          <div className="mb-3 flex items-start gap-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              Security groups are <strong>not enforced</strong> on this VM&apos;s
              host: the agent realizing it predates security-group support, so
              the groups below filter nothing. Upgrade the agent to enforce
              them.
            </span>
          </div>
        )}
        {interfaces.length === 0 ? (
          <div className="text-center py-6 text-muted-foreground">
            No network interfaces.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Device
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Network
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MAC
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Addresses
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Observed (guest)
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Gateway
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MTU
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  State
                </TableHead>
                {showSecurityGroups && (
                  <TableHead className="text-muted-foreground font-medium">
                    Security groups
                  </TableHead>
                )}
                <TableHead className="text-muted-foreground font-medium text-right">
                  Actions
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {interfaces.map((nic) => (
                <TableRow
                  key={nic.id ?? nic.deviceName}
                  className="border-border hover:bg-accent/60"
                >
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.deviceName}
                  </TableCell>
                  <TableCell className="text-foreground/80">
                    {nic.network ?? nic.networkId}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.macAddress}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicAddresses(nic).length > 0
                      ? nicAddresses(nic).map((address) => (
                          <div key={address}>{address}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicObservedAddresses(nic).length > 0
                      ? nicObservedAddresses(nic).map((address) => (
                          <div key={address}>{address}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicGateways(nic).length > 0
                      ? nicGateways(nic).map((gateway) => (
                          <div key={gateway}>{gateway}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80">
                    {nic.mtu ?? "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 text-sm">
                    <div>
                      {nic.attachmentState?.replaceAll("_", " ") ?? "attached"}
                    </div>
                    {nic.attachmentError && (
                      <div className="mt-1 max-w-56 text-xs text-red-600">
                        {nic.attachmentError}
                      </div>
                    )}
                  </TableCell>
                  {showSecurityGroups && (
                    <TableCell>
                      <NicSecurityGroupNames nic={nic} groups={securityGroups} />
                    </TableCell>
                  )}
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-1">
                      {showSecurityGroups && nic.id ? (
                        <NicSecurityGroupMenu
                          target={{ vmId: vm.id }}
                          nic={nic}
                          groups={securityGroups}
                          disabled={mutationPending}
                        />
                      ) : null}
                      {vm.hypervisorType !== "firecracker" && (
                        <>
                          {(nic.attachmentState === "attach_failed" ||
                            nic.attachmentState === "detach_failed") && (
                            <Button
                              size="sm"
                              variant="ghost"
                              aria-label={`Retry ${nic.deviceName}`}
                              onClick={() => retry(nic)}
                              disabled={mutationPending}
                            >
                              {busyKey === nic.id ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <RotateCcw className="h-4 w-4" />
                              )}
                            </Button>
                          )}
                          {nic.id &&
                            nic.attachmentState !== "attaching" &&
                            nic.attachmentState !== "detaching" &&
                            nic.attachmentState !== "detach_failed" && (
                              <Button
                                size="sm"
                                variant="ghost"
                                aria-label={`Detach ${nic.deviceName}`}
                                onClick={() => setDetachNIC(nic)}
                                disabled={mutationPending}
                              >
                                <Trash2 className="h-4 w-4 text-red-600" />
                              </Button>
                            )}
                        </>
                      )}
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        {showSecurityGroups && (
          <p className="mt-3 text-xs text-muted-foreground">
            Every NIC belongs to at least one security group. Rules are managed
            on the{" "}
            <Link
              href="/security-groups"
              className="text-blue-600 hover:underline"
            >
              Security Groups
            </Link>{" "}
            page.
          </p>
        )}
        {securityGroupsFailed && (
          // A failed fetch must not silently hide the security-group UI as if
          // no groups existed.
          <p className="mt-3 text-xs text-red-600">
            Failed to load security groups; group membership cannot be edited
            until the page is refreshed.
          </p>
        )}
        </CardContent>
      </Card>
      <Dialog
        open={showAttach}
        onOpenChange={(open) => (open ? setShowAttach(true) : resetAttach())}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Attach network interface</DialogTitle>
            <DialogDescription>
              The interface receives the lowest free net0–net7 slot. QEMU can
              attach it while this VM is running or stopped.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div className="space-y-2">
              <Label htmlFor="attach-network">Network</Label>
              <select
                id="attach-network"
                value={networkId}
                onChange={(event) => setNetworkId(event.target.value)}
                disabled={mutationPending || networks.length === 0}
                className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm"
              >
                <option value="" disabled>
                  Select a network
                </option>
                {networks
                  .filter((network) => network.id)
                  .map((network) => (
                    <option key={network.id} value={network.id!}>
                      {network.name} ({network.subnet})
                    </option>
                  ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="attach-mtu">MTU (optional)</Label>
              <Input
                id="attach-mtu"
                type="number"
                min="68"
                max="65535"
                placeholder="Network default"
                value={mtu}
                onChange={(event) => setMTU(event.target.value)}
                disabled={mutationPending}
              />
            </div>
            {showSecurityGroups && (
              <div className="space-y-2">
                <Label>Security groups</Label>
                <div className="grid gap-2 rounded-md border border-border p-3 sm:grid-cols-2">
                  {securityGroups.map((group) => {
                    const checked = attachSecurityGroupIds.includes(group.id);
                    const atLimit =
                      !checked &&
                      attachSecurityGroupIds.length >= MAX_SECURITY_GROUPS_PER_NIC;
                    return (
                      <label
                        key={group.id}
                        className="flex items-center gap-2 text-sm"
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          disabled={mutationPending || atLimit}
                          onChange={() =>
                            setAttachSecurityGroupIds((current) =>
                              checked
                                ? current.filter((id) => id !== group.id)
                                : [...current, group.id]
                            )
                          }
                          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                        />
                        {group.name}
                      </label>
                    );
                  })}
                </div>
                <p className="text-xs text-muted-foreground">
                  The project default is used when none are selected.
                </p>
              </div>
            )}
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={resetAttach}
              disabled={mutationPending}
            >
              Cancel
            </Button>
            <Button onClick={attach} disabled={mutationPending || !networkId}>
              {busyKey === "attach" && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Attach interface
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={!!detachNIC}
        onOpenChange={(open) => !open && setDetachNIC(null)}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Detach {detachNIC?.deviceName}?</DialogTitle>
            <DialogDescription>
              The VM may become networkless. Addresses, security groups, and a
              floating IP remain reserved until the agent confirms the device
              is absent.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setDetachNIC(null)}
              disabled={mutationPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              disabled={mutationPending || !detachNIC}
              onClick={() => detachNIC && detach(detachNIC)}
            >
              {detachNIC && busyKey === detachNIC.id && (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              )}
              Detach interface
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
