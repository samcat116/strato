"use client";

import { useMemo, useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { CreateVMDialog } from "@/components/vms";
import {
  AgentHealthDonut,
  BusiestAgents,
  FleetCapacityChart,
  KpiCard,
  RecentInstances,
  CHART_CPU,
  CHART_MEMORY,
  agentStatusColors,
  createdWithinLastDay,
  formatBytes,
  reservedPercent,
} from "@/components/overview";
import { useAgents, useInvalidateVMs, useVMs } from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { AgentStatus } from "@/types/api";

const AGENT_STATUS_ROWS: { status: AgentStatus; label: string }[] = [
  { status: "online", label: "Online" },
  { status: "connecting", label: "Connecting" },
  { status: "error", label: "Error" },
  { status: "offline", label: "Offline" },
];

export default function OverviewPage() {
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const { data: vms = [], isLoading: vmsLoading } = useVMs();
  const { data: agents = [], isLoading: agentsLoading } = useAgents();
  const { currentOrg } = useOrganization();
  const invalidateVMs = useInvalidateVMs();

  const stats = useMemo(() => {
    const running = vms.filter((vm) => vm.status === "Running").length;
    const errored = vms.filter((vm) => vm.status === "Error").length;
    const stopped = vms.filter((vm) => vm.status === "Shutdown").length;
    const newToday = vms.filter((vm) => createdWithinLastDay(vm.createdAt)).length;

    const online = agents.filter((a) => a.isOnline);
    const capacity = online.reduce(
      (acc, a) => ({
        totalCPU: acc.totalCPU + a.resources.totalCPU,
        availableCPU: acc.availableCPU + a.resources.availableCPU,
        totalMemory: acc.totalMemory + a.resources.totalMemory,
        availableMemory: acc.availableMemory + a.resources.availableMemory,
        totalDisk: acc.totalDisk + a.resources.totalDisk,
        availableDisk: acc.availableDisk + a.resources.availableDisk,
      }),
      {
        totalCPU: 0,
        availableCPU: 0,
        totalMemory: 0,
        availableMemory: 0,
        totalDisk: 0,
        availableDisk: 0,
      }
    );

    const statusCounts = agents.reduce(
      (acc, a) => {
        acc[a.status] = (acc[a.status] ?? 0) + 1;
        return acc;
      },
      {} as Record<AgentStatus, number>
    );
    const offlineAgents = agents.filter((a) => !a.isOnline);

    return {
      running,
      errored,
      stopped,
      newToday,
      online,
      capacity,
      statusCounts,
      offlineAgents,
      cpuPct: reservedPercent(capacity.totalCPU, capacity.availableCPU),
      memPct: reservedPercent(capacity.totalMemory, capacity.availableMemory),
      diskPct: reservedPercent(capacity.totalDisk, capacity.availableDisk),
    };
  }, [vms, agents]);

  const loading = (vmsLoading && vms.length === 0) || (agentsLoading && agents.length === 0);

  const runningSub =
    stats.errored > 0
      ? { text: `${stats.errored} in error`, tone: "negative" as const }
      : stats.newToday > 0
        ? { text: `+${stats.newToday} today`, tone: "positive" as const }
        : { text: `${stats.stopped} stopped`, tone: "neutral" as const };

  const agentsSub =
    stats.offlineAgents.length > 0
      ? {
          text: `${stats.offlineAgents.length} offline · ${stats.offlineAgents[0].name}`,
          tone: "negative" as const,
        }
      : agents.length > 0
        ? { text: "all online", tone: "positive" as const }
        : { text: "none registered", tone: "neutral" as const };

  return (
    <div className="mx-auto max-w-[1360px] space-y-3.5">
      {/* Header */}
      <div className="mb-4 flex items-center gap-3.5">
        <div>
          <h1 className="text-[22px] font-bold tracking-tight">Overview</h1>
          <div className="mt-0.5 font-mono text-[12.5px] text-muted-foreground">
            {currentOrg?.name ?? "—"} · {agents.length}{" "}
            {agents.length === 1 ? "agent" : "agents"} · {vms.length}{" "}
            {vms.length === 1 ? "instance" : "instances"}
          </div>
        </div>
        <div className="flex-1" />
        <Button
          onClick={() => setCreateVMOpen(true)}
          className="h-[34px] rounded-lg px-4 text-[12.5px] font-semibold"
        >
          <Plus className="h-3.5 w-3.5" strokeWidth={2.2} />
          New Instance
        </Button>
      </div>

      {loading ? (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-[104px] rounded-[11px]" />
          ))}
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <KpiCard
            label="Running"
            value={String(stats.running)}
            unit={`/${vms.length}`}
            sub={runningSub.text}
            tone={runningSub.tone}
          />
          <KpiCard
            label="vCPU reserved"
            value={String(stats.cpuPct)}
            unit="%"
            sub={`${Math.max(0, stats.capacity.totalCPU - stats.capacity.availableCPU)} of ${stats.capacity.totalCPU} vCPU`}
          />
          <KpiCard
            label="Memory reserved"
            value={String(stats.memPct)}
            unit="%"
            sub={`${formatBytes(Math.max(0, stats.capacity.totalMemory - stats.capacity.availableMemory))} of ${formatBytes(stats.capacity.totalMemory)}`}
          />
          <KpiCard
            label="Agents"
            value={String(stats.online.length)}
            unit={`/${agents.length}`}
            sub={agentsSub.text}
            tone={agentsSub.tone}
          />
          <KpiCard
            label="Storage reserved"
            value={String(stats.diskPct)}
            unit="%"
            sub={`${formatBytes(Math.max(0, stats.capacity.totalDisk - stats.capacity.availableDisk))} of ${formatBytes(stats.capacity.totalDisk)}`}
          />
        </div>
      )}

      {/* Charts row */}
      <div className="grid gap-3.5 xl:grid-cols-[1fr_340px]">
        <div className="rounded-[11px] border border-border bg-card px-[18px] py-4">
          <div className="mb-3.5 flex items-center">
            <span className="text-[13.5px] font-semibold">Fleet resource usage</span>
            <div className="flex-1" />
            <div className="flex gap-4 font-mono text-[11.5px] text-muted-foreground">
              <span className="flex items-center gap-1.5">
                <span
                  className="h-[9px] w-[9px] rounded-sm"
                  style={{ background: CHART_CPU }}
                />
                CPU {stats.cpuPct}%
              </span>
              <span className="flex items-center gap-1.5">
                <span
                  className="h-[9px] w-[9px] rounded-sm"
                  style={{ background: CHART_MEMORY }}
                />
                Memory {stats.memPct}%
              </span>
            </div>
          </div>
          <FleetCapacityChart agents={agents} />
        </div>

        <div className="rounded-[11px] border border-border bg-card px-[18px] py-4">
          <div className="mb-3 text-[13.5px] font-semibold">Agent health</div>
          <div className="flex items-center gap-[18px]">
            <AgentHealthDonut
              total={agents.length}
              segments={AGENT_STATUS_ROWS.map(({ status }) => ({
                value: stats.statusCounts[status] ?? 0,
                color: agentStatusColors[status],
              }))}
            />
            <div className="flex flex-1 flex-col gap-2.5">
              {AGENT_STATUS_ROWS.map(({ status, label }) => (
                <div key={status} className="flex items-center gap-2 text-[12.5px]">
                  <span
                    className="h-[9px] w-[9px] rounded-full"
                    style={{ background: agentStatusColors[status] }}
                  />
                  <span className="flex-1 text-foreground/75">{label}</span>
                  <b className="font-mono">{stats.statusCounts[status] ?? 0}</b>
                </div>
              ))}
            </div>
          </div>
          <div className="mt-3.5 border-t border-muted pt-3">
            <div className="mb-2 text-[10px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">
              Busiest agents
            </div>
            <BusiestAgents agents={agents} />
          </div>
        </div>
      </div>

      {/* Recent instances */}
      <RecentInstances vms={vms} agents={agents} />

      <CreateVMDialog
        open={createVMOpen}
        onOpenChange={setCreateVMOpen}
        onCreated={invalidateVMs}
      />
    </div>
  );
}
