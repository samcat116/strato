"use client";

import { Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { UsageBar } from "./usage-bar";
import type { ResourceQuota } from "@/types/api";

interface QuotaCardProps {
  quota: ResourceQuota;
  canManage: boolean;
  onEdit: (quota: ResourceQuota) => void;
  onDelete: (quota: ResourceQuota) => void;
}

export function QuotaCard({
  quota,
  canManage,
  onEdit,
  onDelete,
}: QuotaCardProps) {
  const { limits, usage, utilization } = quota;

  return (
    <div className="rounded-lg border border-border bg-muted/50 p-4 space-y-3">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-foreground truncate">
              {quota.name}
            </span>
            {!quota.isEnabled && (
              <Badge
                variant="outline"
                className="border-input text-muted-foreground"
              >
                Disabled
              </Badge>
            )}
            {quota.environment && (
              <Badge
                variant="outline"
                className="border-blue-500/40 text-blue-700"
              >
                {quota.environment}
              </Badge>
            )}
          </div>
        </div>
        {canManage && (
          <div className="flex shrink-0 gap-1">
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7 text-muted-foreground hover:text-foreground hover:bg-accent"
              onClick={() => onEdit(quota)}
              aria-label="Edit quota"
            >
              <Pencil className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7 text-muted-foreground hover:text-red-600 hover:bg-accent"
              onClick={() => onDelete(quota)}
              aria-label="Delete quota"
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          </div>
        )}
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <UsageBar
          label="vCPUs"
          used={usage.reservedVCPUs}
          limit={limits.maxVCPUs}
          percent={utilization.cpuPercent}
        />
        <UsageBar
          label="Memory"
          used={usage.reservedMemoryGB}
          limit={limits.maxMemoryGB}
          unit="GB"
          decimals={1}
          percent={utilization.memoryPercent}
        />
        <UsageBar
          label="Storage"
          used={usage.reservedStorageGB}
          limit={limits.maxStorageGB}
          unit="GB"
          decimals={1}
          percent={utilization.storagePercent}
        />
        <UsageBar
          label="VMs"
          used={usage.vmCount}
          limit={limits.maxVMs}
          percent={utilization.vmPercent}
        />
      </div>

      <div className="text-xs text-muted-foreground">
        Networks: {usage.networkCount} / {limits.maxNetworks}
      </div>
    </div>
  );
}
