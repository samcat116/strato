"use client";

import { useState } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
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
import { securityGroupsApi } from "@/lib/api/security-groups";
import { toast } from "sonner";
import type {
  CreateSecurityGroupRuleRequest,
  Ethertype,
  SecurityGroup,
  SecurityGroupRule,
  SecurityGroupRuleDirection,
} from "@/types/api";

interface SecurityGroupRulesDialogProps {
  group: SecurityGroup | null;
  /** All groups in the project, for the remote-group peer selector and names. */
  groups: SecurityGroup[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChanged?: () => void;
}

const selectClassName =
  "w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

/** "Ingress IPv4 TCP 443 from 0.0.0.0/0" / "Egress IPv6 any to group web". */
function ruleSummary(
  rule: SecurityGroupRule,
  groupNameById: Map<string, string>
): string {
  const direction = rule.direction === "ingress" ? "Ingress" : "Egress";
  const ethertype = rule.ethertype === "ipv4" ? "IPv4" : "IPv6";
  const protocol = rule.protocolName ? rule.protocolName.toUpperCase() : "any";

  let ports = "";
  if (rule.protocolName === "icmp") {
    if (rule.portRangeMin != null) {
      ports = ` type ${rule.portRangeMin}`;
      if (rule.portRangeMax != null) ports += ` code ${rule.portRangeMax}`;
    }
  } else if (rule.protocolName && rule.portRangeMin != null) {
    ports =
      rule.portRangeMax != null && rule.portRangeMax !== rule.portRangeMin
        ? ` ${rule.portRangeMin}–${rule.portRangeMax}`
        : ` ${rule.portRangeMin}`;
  }

  const peerWord = rule.direction === "ingress" ? "from" : "to";
  const peer = rule.remoteCIDR
    ? rule.remoteCIDR
    : rule.remoteGroupId
      ? `group ${groupNameById.get(rule.remoteGroupId) ?? rule.remoteGroupId}`
      : "any";

  return `${direction} ${ethertype} ${protocol}${ports} ${peerWord} ${peer}`;
}

export function SecurityGroupRulesDialog({
  group,
  groups,
  open,
  onOpenChange,
  onChanged,
}: SecurityGroupRulesDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl max-h-[85vh] overflow-y-auto">
        {group && (
          // Keyed on the group id so switching targets remounts with fresh
          // form state.
          <SecurityGroupRules
            key={group.id}
            group={group}
            groups={groups}
            onChanged={onChanged}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function SecurityGroupRules({
  group,
  groups,
  onChanged,
}: {
  group: SecurityGroup;
  groups: SecurityGroup[];
  onChanged?: () => void;
}) {
  const [busyRuleId, setBusyRuleId] = useState<string | null>(null);
  const [isAdding, setIsAdding] = useState(false);
  const [form, setForm] = useState({
    direction: "ingress" as SecurityGroupRuleDirection,
    ethertype: "ipv4" as Ethertype,
    protocol: "",
    portMin: "",
    portMax: "",
    peerType: "any" as "any" | "cidr" | "group",
    cidr: "",
    remoteGroupId: "",
    description: "",
  });

  const groupNameById = new Map(groups.map((g) => [g.id, g.name]));
  const isIcmp = form.protocol === "icmp";
  const hasPorts = form.protocol === "tcp" || form.protocol === "udp" || isIcmp;

  const ingressRules = group.rules.filter((r) => r.direction === "ingress");
  const egressRules = group.rules.filter((r) => r.direction === "egress");

  const handleDeleteRule = async (rule: SecurityGroupRule) => {
    setBusyRuleId(rule.id);
    try {
      await securityGroupsApi.deleteRule(group.id, rule.id);
      toast.success("Rule deleted");
      onChanged?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete rule"
      );
    } finally {
      setBusyRuleId(null);
    }
  };

  const handleAddRule = async (e: React.FormEvent) => {
    e.preventDefault();

    const cidr = form.cidr.trim();
    if (form.peerType === "cidr" && !cidr) {
      toast.error("Please enter a CIDR, e.g. 0.0.0.0/0");
      return;
    }
    if (form.peerType === "group" && !form.remoteGroupId) {
      toast.error("Please select a security group as the peer");
      return;
    }

    const portMin = form.portMin.trim();
    // tcp/udp require both bounds or neither; a single filled field means a
    // single port, so mirror it rather than send a request the API rejects.
    // ICMP is different: a type without a code is legal (code stays empty).
    let portMax = form.portMax.trim();
    if (!isIcmp && portMin && !portMax) portMax = portMin;
    if (!isIcmp && portMax && !portMin) {
      toast.error("Enter the first port of the range (or leave both empty)");
      return;
    }
    const data: CreateSecurityGroupRuleRequest = {
      direction: form.direction,
      ethertype: form.ethertype,
      protocolName: form.protocol || undefined,
      portRangeMin: hasPorts && portMin ? parseInt(portMin) : undefined,
      portRangeMax: hasPorts && portMax ? parseInt(portMax) : undefined,
      remoteCIDR: form.peerType === "cidr" ? cidr : undefined,
      remoteGroupId:
        form.peerType === "group" ? form.remoteGroupId : undefined,
      description: form.description.trim() || undefined,
    };

    setIsAdding(true);
    try {
      await securityGroupsApi.createRule(group.id, data);
      toast.success("Rule added");
      onChanged?.();
      setForm((prev) => ({
        ...prev,
        portMin: "",
        portMax: "",
        cidr: "",
        description: "",
      }));
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to add rule"
      );
    } finally {
      setIsAdding(false);
    }
  };

  const renderRuleList = (label: string, rules: SecurityGroupRule[]) => (
    <div className="space-y-1">
      <p className="text-sm font-medium text-foreground">{label}</p>
      {rules.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No {label.toLowerCase()} rules — this direction allows no traffic.
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border">
          {rules.map((rule) => (
            <li
              key={rule.id}
              className="flex items-center justify-between gap-2 px-3 py-2"
            >
              <div className="min-w-0">
                <p className="text-sm text-foreground/80">
                  {ruleSummary(rule, groupNameById)}
                </p>
                {rule.description && (
                  <p className="text-xs text-muted-foreground truncate">
                    {rule.description}
                  </p>
                )}
              </div>
              <Button
                size="sm"
                variant="ghost"
                className="text-red-600 hover:text-red-700 hover:bg-red-500/10 shrink-0"
                onClick={() => handleDeleteRule(rule)}
                disabled={busyRuleId === rule.id}
                title="Delete rule"
              >
                {busyRuleId === rule.id ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <Trash2 className="h-4 w-4" />
                )}
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );

  return (
    <>
      <DialogHeader>
        <DialogTitle>Rules for {group.name}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Rules are allow-only: traffic not matched by any rule is dropped.
        </DialogDescription>
      </DialogHeader>

      <div className="space-y-4 py-2">
        {renderRuleList("Ingress", ingressRules)}
        {renderRuleList("Egress", egressRules)}
      </div>

      <form onSubmit={handleAddRule}>
        <div className="space-y-4 rounded-md border border-border p-3">
          <p className="text-sm font-medium text-foreground">Add rule</p>
          <div className="grid grid-cols-3 gap-4">
            <div className="space-y-2">
              <Label htmlFor="ruleDirection" className="text-foreground">
                Direction
              </Label>
              <select
                id="ruleDirection"
                value={form.direction}
                onChange={(e) =>
                  setForm({
                    ...form,
                    direction: e.target.value as SecurityGroupRuleDirection,
                  })
                }
                disabled={isAdding}
                className={selectClassName}
              >
                <option value="ingress">Ingress</option>
                <option value="egress">Egress</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="ruleEthertype" className="text-foreground">
                Ethertype
              </Label>
              <select
                id="ruleEthertype"
                value={form.ethertype}
                onChange={(e) =>
                  setForm({ ...form, ethertype: e.target.value as Ethertype })
                }
                disabled={isAdding}
                className={selectClassName}
              >
                <option value="ipv4">IPv4</option>
                <option value="ipv6">IPv6</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="ruleProtocol" className="text-foreground">
                Protocol
              </Label>
              <select
                id="ruleProtocol"
                value={form.protocol}
                onChange={(e) =>
                  setForm({
                    ...form,
                    protocol: e.target.value,
                    portMin: "",
                    portMax: "",
                  })
                }
                disabled={isAdding}
                className={selectClassName}
              >
                <option value="">Any</option>
                <option value="tcp">TCP</option>
                <option value="udp">UDP</option>
                <option value="icmp">ICMP</option>
              </select>
            </div>
          </div>

          {hasPorts && (
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="rulePortMin" className="text-foreground">
                  {isIcmp ? "Type" : "Port from"}
                </Label>
                <Input
                  id="rulePortMin"
                  type="number"
                  min="0"
                  max={isIcmp ? 255 : 65535}
                  placeholder={isIcmp ? "8" : "443"}
                  value={form.portMin}
                  onChange={(e) => setForm({ ...form, portMin: e.target.value })}
                  className="bg-background border-border text-foreground"
                  disabled={isAdding}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="rulePortMax" className="text-foreground">
                  {isIcmp ? "Code" : "Port to"}
                </Label>
                <Input
                  id="rulePortMax"
                  type="number"
                  min="0"
                  max={isIcmp ? 255 : 65535}
                  placeholder={isIcmp ? "0" : "443"}
                  value={form.portMax}
                  onChange={(e) => setForm({ ...form, portMax: e.target.value })}
                  className="bg-background border-border text-foreground"
                  disabled={isAdding}
                />
              </div>
              <p className="col-span-2 text-xs text-muted-foreground -mt-2">
                {isIcmp
                  ? "Leave empty to match all ICMP types."
                  : "Leave empty to match all ports; a single value matches one port."}
              </p>
            </div>
          )}

          <div className="space-y-2">
            <Label className="text-foreground">Peer</Label>
            <div className="flex items-center gap-4">
              {(
                [
                  ["any", "Any"],
                  ["cidr", "CIDR"],
                  ["group", "Security group"],
                ] as const
              ).map(([value, label]) => (
                <label
                  key={value}
                  className="flex items-center gap-2 text-sm text-foreground"
                >
                  <input
                    type="radio"
                    name="rulePeerType"
                    value={value}
                    checked={form.peerType === value}
                    onChange={() => setForm({ ...form, peerType: value })}
                    disabled={isAdding}
                    className="h-4 w-4 accent-primary"
                  />
                  {label}
                </label>
              ))}
            </div>
            {form.peerType === "cidr" && (
              <Input
                id="ruleCidr"
                placeholder={form.ethertype === "ipv4" ? "0.0.0.0/0" : "::/0"}
                value={form.cidr}
                onChange={(e) => setForm({ ...form, cidr: e.target.value })}
                className="bg-background border-border text-foreground font-mono"
                disabled={isAdding}
              />
            )}
            {form.peerType === "group" && (
              <select
                id="ruleRemoteGroup"
                value={form.remoteGroupId}
                onChange={(e) =>
                  setForm({ ...form, remoteGroupId: e.target.value })
                }
                disabled={isAdding}
                className={selectClassName}
              >
                <option value="" disabled>
                  Select a security group
                </option>
                {groups.map((g) => (
                  <option key={g.id} value={g.id}>
                    {g.name}
                  </option>
                ))}
              </select>
            )}
          </div>

          <div className="space-y-2">
            <Label htmlFor="ruleDescription" className="text-foreground">
              Description (optional)
            </Label>
            <Input
              id="ruleDescription"
              placeholder="Allow HTTPS from anywhere"
              value={form.description}
              onChange={(e) => setForm({ ...form, description: e.target.value })}
              className="bg-background border-border text-foreground"
              disabled={isAdding}
            />
          </div>

          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isAdding}
          >
            {isAdding ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Adding...
              </>
            ) : (
              <>
                <Plus className="h-4 w-4 mr-2" />
                Add Rule
              </>
            )}
          </Button>
        </div>
      </form>
    </>
  );
}
