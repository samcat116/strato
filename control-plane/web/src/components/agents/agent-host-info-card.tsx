"use client";

import { Server } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { Agent } from "@/types/api";

// Host memory can be reported in host-info; fall back to the scheduler's total
// so the card still shows a value for pre-host-info agents.
function formatBytes(bytes: number | undefined): string | undefined {
  if (bytes == null) return undefined;
  const gb = bytes / 1024 ** 3;
  if (gb >= 1024) return `${(gb / 1024).toFixed(1)} TB`;
  if (gb >= 1) return `${gb.toFixed(0)} GB`;
  return `${(bytes / 1024 ** 2).toFixed(0)} MB`;
}

function formatCores(
  physical: number | undefined,
  logical: number | undefined,
): string | undefined {
  const parts: string[] = [];
  if (physical != null) parts.push(`${physical} physical`);
  if (logical != null) parts.push(`${logical} logical`);
  return parts.length > 0 ? parts.join(" · ") : undefined;
}

function formatBoot(bootTime: string | undefined): string | undefined {
  if (!bootTime) return undefined;
  const boot = new Date(bootTime);
  const ms = Date.now() - boot.getTime();
  if (Number.isNaN(ms) || ms < 0) return boot.toLocaleString();

  const days = Math.floor(ms / 86_400_000);
  const hours = Math.floor((ms % 86_400_000) / 3_600_000);
  const mins = Math.floor((ms % 3_600_000) / 60_000);
  let uptime: string;
  if (days > 0) uptime = `${days}d ${hours}h`;
  else if (hours > 0) uptime = `${hours}h ${mins}m`;
  else uptime = `${mins}m`;

  return `up ${uptime} (since ${boot.toLocaleString()})`;
}

export function AgentHostInfoCard({ agent }: { agent: Agent }) {
  const host = agent.hostInfo;

  // OS name and memory prefer the richer host-info values but fall back to the
  // fields Strato has always had, so the card is useful even before an agent
  // re-registers with a host-info-capable build.
  const rows: { label: string; value: string | undefined }[] = [
    { label: "CPU", value: host?.cpuModel },
    { label: "CPU vendor", value: host?.cpuVendor },
    { label: "Cores", value: formatCores(host?.physicalCoreCount, host?.logicalCoreCount) },
    { label: "Architecture", value: agent.architecture },
    {
      label: "Memory",
      value: formatBytes(host?.totalMemoryBytes ?? agent.resources.totalMemory),
    },
    { label: "Machine model", value: host?.machineModel },
    { label: "Operating system", value: host?.osName ?? agent.operatingSystem },
    { label: "Kernel", value: host?.kernelVersion },
    {
      label: "Networking",
      value:
        agent.networkCapability === "overlay"
          ? "Overlay (OVN)"
          : agent.networkCapability === "user_mode"
            ? "User mode (SLIRP)"
            : undefined,
    },
    { label: "Boot time", value: formatBoot(host?.bootTime) },
  ];

  const shown = rows.filter((r) => r.value != null && r.value !== "");

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
          <Server className="h-5 w-5" />
          Host
        </CardTitle>
      </CardHeader>
      <CardContent>
        {shown.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No host details reported yet. They appear after the agent registers with a build that
            reports host information.
          </p>
        ) : (
          <dl className="grid grid-cols-2 gap-4 text-sm">
            {shown.map((row) => (
              <div key={row.label}>
                <dt className="text-muted-foreground">{row.label}</dt>
                <dd className="text-foreground break-words">{row.value}</dd>
              </div>
            ))}
          </dl>
        )}
      </CardContent>
    </Card>
  );
}
