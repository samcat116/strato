"use client";

import { errorMessage } from "@/lib/errors";

import { useState } from "react";
import { AlertTriangle, Loader2, Plus, Shield, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useCreateNetworkACL,
  useCreateNetworkACLRule,
  useDeleteNetworkACL,
  useDeleteNetworkACLRule,
  useNetworkACL,
} from "@/lib/hooks/use-networks";
import type {
  CreateNetworkACLRuleRequest,
  Network,
  NetworkACLRule,
  NetworkACLRuleAction,
  NetworkACLRuleDirection,
  NetworkACLRuleEthertype,
} from "@/types/api";
import { MAX_NETWORK_ACL_RULES } from "@/types/api";

interface NetworkACLDialogProps {
  network: Network | null;
  canManage: boolean;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const selectClassName =
  "w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

function ruleSummary(rule: NetworkACLRule): string {
  const family = rule.ethertype === "ipv4" ? "IPv4" : "IPv6";
  const protocol = rule.protocolName?.toUpperCase() ?? "any protocol";

  let ports = "";
  if (rule.protocolName === "icmp" && rule.portRangeMin != null) {
    ports = ` type ${rule.portRangeMin}`;
    if (rule.portRangeMax != null) ports += ` code ${rule.portRangeMax}`;
  } else if (rule.protocolName && rule.portRangeMin != null) {
    ports =
      rule.portRangeMax != null && rule.portRangeMax !== rule.portRangeMin
        ? ` ${rule.portRangeMin}–${rule.portRangeMax}`
        : ` ${rule.portRangeMin}`;
  }

  const peerWord = rule.direction === "ingress" ? "from" : "to";
  return `${family} ${protocol}${ports} ${peerWord} ${rule.remoteCIDR}`;
}

export function NetworkACLDialog({
  network,
  canManage,
  open,
  onOpenChange,
}: NetworkACLDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-3xl max-h-[90vh] overflow-y-auto">
        {network?.id && (
          <NetworkACLManager
            key={network.id}
            networkId={network.id}
            networkName={network.name}
            canManage={canManage}
            queryEnabled={open}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function NetworkACLManager({
  networkId,
  networkName,
  canManage,
  queryEnabled,
}: {
  networkId: string;
  networkName: string;
  canManage: boolean;
  queryEnabled: boolean;
}) {
  const aclQuery = useNetworkACL(networkId, queryEnabled);
  const createACL = useCreateNetworkACL(networkId);
  const deleteACL = useDeleteNetworkACL(networkId);
  const createRule = useCreateNetworkACLRule(networkId);
  const deleteRule = useDeleteNetworkACLRule(networkId);
  const [busyRuleId, setBusyRuleId] = useState<string | null>(null);
  const [form, setForm] = useState({
    ruleNumber: "100",
    direction: "ingress" as NetworkACLRuleDirection,
    ethertype: "ipv4" as NetworkACLRuleEthertype,
    action: "allow" as NetworkACLRuleAction,
    protocol: "" as "" | "tcp" | "udp" | "icmp",
    portMin: "",
    portMax: "",
    remoteCIDR: "",
    description: "",
  });

  const acl = aclQuery.data;
  const isIcmp = form.protocol === "icmp";
  const hasPorts = form.protocol !== "";
  const isMutating =
    createACL.isPending ||
    deleteACL.isPending ||
    createRule.isPending ||
    deleteRule.isPending;

  const handleCreateACL = async () => {
    if (!canManage) return;
    if (
      !confirm(
        `Create an empty ACL for "${networkName}"? Unmatched ingress and egress IP traffic will be denied immediately.`
      )
    ) {
      return;
    }

    try {
      await createACL.mutateAsync();
      toast.success(`Network ACL created for "${networkName}"`);
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to create network ACL")
      );
    }
  };

  const handleDeleteACL = async () => {
    if (!canManage) return;
    if (
      !confirm(
        `Delete the ACL for "${networkName}"? Network-level filtering and all of its rules will be removed; NIC security groups will continue to apply.`
      )
    ) {
      return;
    }

    try {
      await deleteACL.mutateAsync();
      toast.success(`Network ACL deleted from "${networkName}"`);
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to delete network ACL")
      );
    }
  };

  const handleDeleteRule = async (rule: NetworkACLRule) => {
    if (!canManage) return;
    if (
      !confirm(
        `Delete ${rule.direction} rule #${rule.ruleNumber}? The next matching rule, or the default deny, will take effect.`
      )
    ) {
      return;
    }

    setBusyRuleId(rule.id);
    try {
      await deleteRule.mutateAsync(rule.id);
      toast.success(`Rule #${rule.ruleNumber} deleted`);
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to delete rule")
      );
    } finally {
      setBusyRuleId(null);
    }
  };

  const handleAddRule = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!canManage) return;

    const ruleNumber = Number(form.ruleNumber);
    if (!Number.isInteger(ruleNumber) || ruleNumber < 1 || ruleNumber > 32766) {
      toast.error("Rule number must be an integer from 1 through 32766");
      return;
    }

    const remoteCIDR = form.remoteCIDR.trim();
    if (!remoteCIDR) {
      toast.error(
        `Enter the ${form.direction === "ingress" ? "source" : "destination"} CIDR`
      );
      return;
    }

    const portMin = form.portMin.trim();
    let portMax = form.portMax.trim();
    if (!isIcmp && portMin && !portMax) portMax = portMin;
    if (!isIcmp && portMax && !portMin) {
      toast.error("Enter the first port of the range (or leave both empty)");
      return;
    }
    if (isIcmp && portMax && !portMin) {
      toast.error("An ICMP code needs an ICMP type");
      return;
    }

    const data: CreateNetworkACLRuleRequest = {
      ruleNumber,
      direction: form.direction,
      ethertype: form.ethertype,
      action: form.action,
      protocolName: form.protocol || undefined,
      portRangeMin: hasPorts && portMin ? Number(portMin) : undefined,
      portRangeMax: hasPorts && portMax ? Number(portMax) : undefined,
      remoteCIDR,
      description: form.description.trim() || undefined,
    };

    try {
      await createRule.mutateAsync(data);
      toast.success(`${form.direction} rule #${ruleNumber} added`);
      setForm((previous) => ({
        ...previous,
        ruleNumber: String(Math.min(ruleNumber + 10, 32766)),
        portMin: "",
        portMax: "",
        remoteCIDR: "",
        description: "",
      }));
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to add rule")
      );
    }
  };

  if (aclQuery.isLoading) {
    return (
      <>
        <DialogHeader>
          <DialogTitle>Network ACL for {networkName}</DialogTitle>
          <DialogDescription>Loading the network policy…</DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Skeleton className="h-20 w-full" />
          <Skeleton className="h-32 w-full" />
        </div>
      </>
    );
  }

  if (aclQuery.isError) {
    return (
      <>
        <DialogHeader>
          <DialogTitle>Network ACL for {networkName}</DialogTitle>
          <DialogDescription>
            The network policy could not be loaded.
          </DialogDescription>
        </DialogHeader>
        <div className="rounded-md border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-700 dark:text-red-300">
          {aclQuery.error instanceof Error
            ? aclQuery.error.message
            : "Failed to load network ACL"}
        </div>
        <Button
          type="button"
          variant="outline"
          onClick={() => void aclQuery.refetch()}
        >
          Try Again
        </Button>
      </>
    );
  }

  if (!acl) {
    return (
      <>
        <DialogHeader>
          <DialogTitle>Network ACL for {networkName}</DialogTitle>
          <DialogDescription>
            This network has no network-level ACL. NIC security groups still
            apply normally.
          </DialogDescription>
        </DialogHeader>

        <div className="flex gap-3 rounded-md border border-amber-500/40 bg-amber-500/10 p-4">
          <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-600" />
          <div className="space-y-1 text-sm">
            <p className="font-medium text-foreground">
              An empty ACL is default-deny in both directions
            </p>
            <p className="text-muted-foreground">
              Creating the ACL immediately blocks unmatched ingress and egress
              IP traffic. Add explicit rules to permit the traffic this network
              needs. Lower rule numbers run first.
            </p>
          </div>
        </div>

        {canManage ? (
          <Button
            type="button"
            className="w-fit bg-primary hover:bg-primary/90"
            onClick={() => void handleCreateACL()}
            disabled={createACL.isPending}
          >
            {createACL.isPending ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Shield className="mr-2 h-4 w-4" />
            )}
            Create Empty ACL
          </Button>
        ) : (
          <p className="text-sm text-muted-foreground">
            Read-only access: you can inspect this network&apos;s ACL but cannot
            create or change it.
          </p>
        )}
      </>
    );
  }

  const ingressRules = acl.rules
    .filter((rule) => rule.direction === "ingress")
    .sort((left, right) => left.ruleNumber - right.ruleNumber);
  const egressRules = acl.rules
    .filter((rule) => rule.direction === "egress")
    .sort((left, right) => left.ruleNumber - right.ruleNumber);

  const renderRuleList = (
    label: "Ingress" | "Egress",
    rules: NetworkACLRule[]
  ) => (
    <div className="space-y-1">
      <p className="text-sm font-medium text-foreground">{label}</p>
      {rules.length === 0 ? (
        <p className="rounded-md border border-dashed border-border p-3 text-sm text-muted-foreground">
          No {label.toLowerCase()} rules — this direction denies all IP traffic.
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border">
          {rules.map((rule) => (
            <li
              key={rule.id}
              className="flex items-center justify-between gap-3 px-3 py-2"
            >
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-mono text-sm font-medium text-foreground">
                    #{rule.ruleNumber}
                  </span>
                  <Badge
                    variant={rule.action === "deny" ? "destructive" : "secondary"}
                  >
                    {rule.action}
                  </Badge>
                  <span className="text-sm text-foreground/80">
                    {ruleSummary(rule)}
                  </span>
                </div>
                {rule.description && (
                  <p className="mt-1 truncate text-xs text-muted-foreground">
                    {rule.description}
                  </p>
                )}
              </div>
              {canManage && (
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  className="shrink-0 text-red-600 hover:bg-red-500/10 hover:text-red-700"
                  onClick={() => void handleDeleteRule(rule)}
                  disabled={busyRuleId === rule.id || isMutating}
                  aria-label={`Delete ${rule.direction} rule ${rule.ruleNumber}`}
                  title="Delete rule"
                >
                  {busyRuleId === rule.id ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Trash2 className="h-4 w-4" />
                  )}
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );

  return (
    <>
      <DialogHeader>
        <DialogTitle>Network ACL for {networkName}</DialogTitle>
        <DialogDescription>
          Stateless ordered filtering, generation {acl.generation}. Lower rule
          numbers run first; unmatched traffic is denied. An allow must also
          pass the applicable NIC security groups.
        </DialogDescription>
      </DialogHeader>

      <div className="space-y-4 py-1">
        {!canManage && (
          <p className="rounded-md border border-border bg-muted/40 px-3 py-2 text-sm text-muted-foreground">
            Read-only access: rule and ACL mutations are unavailable.
          </p>
        )}
        <div className="rounded-md border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-sm text-muted-foreground">
          New flows are evaluated against the applicable rule in each
          direction. Return traffic already tracked by a security group&apos;s
          stateful connection is not re-evaluated by this network ACL.
        </div>
        {renderRuleList("Ingress", ingressRules)}
        {renderRuleList("Egress", egressRules)}
      </div>

      {canManage && <form onSubmit={handleAddRule}>
        <div className="space-y-4 rounded-md border border-border p-3">
          <div className="flex items-center justify-between gap-3">
            <p className="text-sm font-medium text-foreground">Add rule</p>
            <p className="text-xs text-muted-foreground">
              {acl.rules.length}/{MAX_NETWORK_ACL_RULES} rules
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-4">
            <div className="space-y-2">
              <Label htmlFor="naclRuleNumber">Rule number</Label>
              <Input
                id="naclRuleNumber"
                type="number"
                min="1"
                max="32766"
                step="1"
                value={form.ruleNumber}
                onChange={(event) =>
                  setForm({ ...form, ruleNumber: event.target.value })
                }
                disabled={isMutating}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="naclDirection">Direction</Label>
              <select
                id="naclDirection"
                value={form.direction}
                onChange={(event) =>
                  setForm({
                    ...form,
                    direction: event.target.value as NetworkACLRuleDirection,
                  })
                }
                disabled={isMutating}
                className={selectClassName}
              >
                <option value="ingress">Ingress</option>
                <option value="egress">Egress</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="naclAction">Action</Label>
              <select
                id="naclAction"
                value={form.action}
                onChange={(event) =>
                  setForm({
                    ...form,
                    action: event.target.value as NetworkACLRuleAction,
                  })
                }
                disabled={isMutating}
                className={selectClassName}
              >
                <option value="allow">Allow</option>
                <option value="deny">Deny</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="naclEthertype">Ethertype</Label>
              <select
                id="naclEthertype"
                value={form.ethertype}
                onChange={(event) =>
                  setForm({
                    ...form,
                    ethertype: event.target.value as NetworkACLRuleEthertype,
                    remoteCIDR: "",
                  })
                }
                disabled={isMutating}
                className={selectClassName}
              >
                <option value="ipv4">IPv4</option>
                <option value="ipv6">IPv6</option>
              </select>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="naclProtocol">Protocol</Label>
              <select
                id="naclProtocol"
                value={form.protocol}
                onChange={(event) =>
                  setForm({
                    ...form,
                    protocol: event.target.value as typeof form.protocol,
                    portMin: "",
                    portMax: "",
                  })
                }
                disabled={isMutating}
                className={selectClassName}
              >
                <option value="">Any</option>
                <option value="tcp">TCP</option>
                <option value="udp">UDP</option>
                <option value="icmp">ICMP</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="naclRemoteCIDR">
                {form.direction === "ingress" ? "Source" : "Destination"} CIDR
              </Label>
              <Input
                id="naclRemoteCIDR"
                required
                placeholder={form.ethertype === "ipv4" ? "0.0.0.0/0" : "::/0"}
                value={form.remoteCIDR}
                onChange={(event) =>
                  setForm({ ...form, remoteCIDR: event.target.value })
                }
                className="font-mono"
                disabled={isMutating}
              />
            </div>
          </div>

          {hasPorts && (
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="naclPortMin">
                  {isIcmp ? "ICMP type" : "Port from"}
                </Label>
                <Input
                  id="naclPortMin"
                  type="number"
                  min="0"
                  max={isIcmp ? "255" : "65535"}
                  placeholder={isIcmp ? "8" : "443"}
                  value={form.portMin}
                  onChange={(event) =>
                    setForm({ ...form, portMin: event.target.value })
                  }
                  disabled={isMutating}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="naclPortMax">
                  {isIcmp ? "ICMP code" : "Port to"}
                </Label>
                <Input
                  id="naclPortMax"
                  type="number"
                  min="0"
                  max={isIcmp ? "255" : "65535"}
                  placeholder={isIcmp ? "0" : "443"}
                  value={form.portMax}
                  onChange={(event) =>
                    setForm({ ...form, portMax: event.target.value })
                  }
                  disabled={isMutating}
                />
              </div>
              <p className="-mt-2 text-xs text-muted-foreground sm:col-span-2">
                {isIcmp
                  ? "Leave both empty for all ICMP; a type may be supplied without a code."
                  : "Leave both empty for all ports; one value matches a single port."}
              </p>
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="naclDescription">Description (optional)</Label>
            <Input
              id="naclDescription"
              maxLength={4096}
              placeholder="Allow HTTPS from the office"
              value={form.description}
              onChange={(event) =>
                setForm({ ...form, description: event.target.value })
              }
              disabled={isMutating}
            />
          </div>

          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isMutating || acl.rules.length >= MAX_NETWORK_ACL_RULES}
          >
            {createRule.isPending ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Plus className="mr-2 h-4 w-4" />
            )}
            Add Rule
          </Button>
        </div>
      </form>}

      {canManage && <div className="flex justify-end border-t border-border pt-4">
        <Button
          type="button"
          variant="outline"
          className="border-red-500/40 text-red-600 hover:bg-red-500/10 hover:text-red-700"
          onClick={() => void handleDeleteACL()}
          disabled={isMutating}
        >
          {deleteACL.isPending ? (
            <Loader2 className="mr-2 h-4 w-4 animate-spin" />
          ) : (
            <Trash2 className="mr-2 h-4 w-4" />
          )}
          Delete ACL
        </Button>
      </div>}
    </>
  );
}
