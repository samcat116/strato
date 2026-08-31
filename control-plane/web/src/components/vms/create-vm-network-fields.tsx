"use client";

import type { Dispatch, SetStateAction } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  MAX_SECURITY_GROUPS_PER_NIC,
  type Network,
  type SecurityGroup,
} from "@/types/api";

export interface NICRow {
  key: string;
  networkId: string;
  securityGroupIds: string[];
  mtu: string;
}

export const initialNIC = (): NICRow => ({
  key: "nic-0",
  networkId: "",
  securityGroupIds: [],
  mtu: "",
});

interface VMNetworkInterfacesFieldsProps {
  isLoading: boolean;
  networkInterfaces: NICRow[];
  setNetworkInterfaces: Dispatch<SetStateAction<NICRow[]>>;
  networks: Network[];
  securityGroups: SecurityGroup[];
  securityGroupsFailed: boolean;
}

export function VMNetworkInterfacesFields({
  isLoading,
  networkInterfaces,
  setNetworkInterfaces,
  networks,
  securityGroups,
  securityGroupsFailed,
}: VMNetworkInterfacesFieldsProps) {
  const updateNIC = (key: string, update: Partial<NICRow>) => {
    setNetworkInterfaces((rows) =>
      rows.map((row) => (row.key === key ? { ...row, ...update } : row))
    );
  };

  const toggleSecurityGroup = (key: string, id: string) => {
    setNetworkInterfaces((rows) =>
      rows.map((row) =>
        row.key !== key
          ? row
          : {
              ...row,
              securityGroupIds: row.securityGroupIds.includes(id)
                ? row.securityGroupIds.filter((groupId) => groupId !== id)
                : [...row.securityGroupIds, id],
            }
      )
    );
  };

  return (
    <>
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <Label className="text-foreground">Network interfaces</Label>
            <p className="text-xs text-muted-foreground">
              Add up to eight NICs. Duplicate network selections are allowed.
            </p>
          </div>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={isLoading || networkInterfaces.length >= 8}
            onClick={() =>
              setNetworkInterfaces((rows) => [
                ...rows,
                {
                  ...initialNIC(),
                  key: crypto.randomUUID(),
                },
              ])
            }
          >
            <Plus className="mr-1 h-4 w-4" /> Add NIC
          </Button>
        </div>
      
        {networkInterfaces.map((nic, index) => (
          <div
            key={nic.key}
            className="space-y-3 rounded-md border border-border p-3"
          >
            <div className="flex items-center justify-between">
              <span className="text-sm font-medium">net{index}</span>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                aria-label={`Remove net${index}`}
                disabled={isLoading || networkInterfaces.length === 1}
                onClick={() =>
                  setNetworkInterfaces((rows) =>
                    rows.filter((row) => row.key !== nic.key)
                  )
                }
              >
                <Trash2 className="h-4 w-4 text-red-600" />
              </Button>
            </div>
            <div className="grid gap-3 sm:grid-cols-[1fr_9rem]">
              <div className="space-y-1">
                <Label htmlFor={`network-${nic.key}`}>Network</Label>
                <select
                  id={`network-${nic.key}`}
                  value={nic.networkId}
                  onChange={(event) =>
                    updateNIC(nic.key, { networkId: event.target.value })
                  }
                  disabled={isLoading || networks.length === 0}
                  required
                  className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
                >
                  <option value="" disabled>Select a network</option>
                  {networks.filter((network) => network.id).map((network) => (
                    <option key={network.id} value={network.id!}>
                      {network.name} ({network.subnet})
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-1">
                <Label htmlFor={`mtu-${nic.key}`}>MTU (optional)</Label>
                <Input
                  id={`mtu-${nic.key}`}
                  type="number"
                  min="68"
                  max="65535"
                  placeholder="Network default"
                  value={nic.mtu}
                  onChange={(event) =>
                    updateNIC(nic.key, { mtu: event.target.value })
                  }
                  disabled={isLoading}
                />
              </div>
            </div>
            {securityGroups.length > 0 && (
              <div className="space-y-1">
                <Label>Security groups</Label>
                <div className="grid gap-1 rounded-md border border-border p-2 sm:grid-cols-2">
                  {securityGroups.map((group) => {
                    const checked = nic.securityGroupIds.includes(group.id);
                    const atLimit =
                      !checked &&
                      nic.securityGroupIds.length >= MAX_SECURITY_GROUPS_PER_NIC;
                    return (
                      <label key={group.id} className="flex items-center gap-2 text-sm">
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleSecurityGroup(nic.key, group.id)}
                          disabled={isLoading || atLimit}
                          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                        />
                        <span className="truncate">{group.name}</span>
                      </label>
                    );
                  })}
                </div>
                <p className="text-xs text-muted-foreground">
                  Default group is used when none are selected.
                </p>
              </div>
            )}
          </div>
        ))}
        {networks.length === 0 && (
          <p className="text-xs text-muted-foreground">
            This project has no networks yet. Create one before adding a VM.
          </p>
        )}
      </div>
      {securityGroupsFailed && (
        // A failed fetch must not read as "this project has no groups":
        // the VM would silently land on the default group only.
        <p className="text-xs text-red-600">
          Failed to load security groups — the VM will use the
          project&apos;s default group. Retry from the Security Groups
          page.
        </p>
      )}
    </>
  );
}
