"use client";

import { formatDate, formatDateTime, formatTime } from "@/lib/format-time";

import {
  Cpu,
  HardDrive,
  MemoryStick,
  Clock,
  Activity,
} from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  DetailGrid,
  DetailPageHeader,
  DetailPageLoading,
  DetailPageMissing,
  DetailPageShell,
  StatCard,
} from "@/components/ui/detail-page-shell";
import { Badge } from "@/components/ui/badge";
import { DetailQueryError } from "@/components/ui/detail-query-error";
import { AgentUpdateAction } from "@/components/agents/agent-update-action";
import { AgentAutoUpdateCard } from "@/components/agents/agent-auto-update";
import { AgentWorkloadSafetyCard } from "@/components/agents/agent-workload-safety";
import { AgentHostInfoCard } from "@/components/agents/agent-host-info-card";
import { AgentForceOfflineAction } from "@/components/agents/agent-force-offline-action";
import { formatCapacity } from "@/lib/format-bytes";
import { useAgent, useVMs } from "@/lib/hooks";

export function AgentDetailPage({ agentId: id }: { agentId: string }) {
  const { data: agent, isLoading, error, refetch } = useAgent(id);
  // Guest-reported memory usage (virtio-balloon, issue #567), aggregated over
  // this agent's VMs that are visible in the current org and reporting stats.
  const { data: vms } = useVMs();
  const agentVMs = (vms ?? []).filter((vm) => vm.hypervisorId === id);
  const reportingVMs = agentVMs.filter(
    (vm) => vm.guestMemoryUsedBytes != null
  );
  const guestUsedBytes = reportingVMs.reduce(
    (sum, vm) => sum + (vm.guestMemoryUsedBytes ?? 0),
    0
  );
  const capabilityLabels = [
    ...agent?.hypervisors
      .filter((hypervisor) => hypervisor.available)
      .flatMap((hypervisor) => [
        hypervisor.type === "qemu" ? "QEMU" : "Firecracker",
        ...(hypervisor.capabilities.supportsSnapshots
          ? [hypervisor.type === "qemu" ? "QEMU snapshots" : "Firecracker snapshots"]
          : []),
      ]) ?? [],
    ...(agent?.networkCapability === "overlay"
      ? ["Overlay networking"]
      : agent?.networkCapability === "user_mode"
        ? ["User-mode networking"]
        : []),
    ...(agent?.sandboxCapable ? ["Sandbox runtime"] : []),
    ...(agent?.sandboxNetworkingCapable ? ["Sandbox networking"] : []),
    ...(agent?.tpmCapable ? ["vTPM"] : []),
    ...(agent?.resolverCapable ? ["DNS resolver"] : []),
    ...(agent?.metadataServiceCapable ? ["Instance metadata"] : []),
  ];

  if (!id) {
    return (
      <DetailPageMissing
        message="No Agent ID provided"
        backHref="/agents"
        backLabel="Back to Agents"
      />
    );
  }

  if (isLoading) {
    return <DetailPageLoading />;
  }

  if (error || !agent) {
    return (
      <DetailQueryError
        resourceName="Agent"
        backHref="/agents"
        backLabel="Back to Agents"
        error={error}
        onRetry={() => void refetch()}
      />
    );
  }

  return (
    <DetailPageShell>
      <DetailPageHeader
        backHref="/agents"
        backLabel="Back to Agents"
        title={agent.name}
        badge={
          <Badge
              variant={agent.isOnline ? "default" : "secondary"}
              className={agent.isOnline ? "bg-green-600" : "bg-muted"}
            >
              {agent.isOnline ? "Online" : "Offline"}
          </Badge>
        }
        description={agent.hostname}
        actions={
          <div className="flex items-center gap-2">
            <AgentForceOfflineAction agent={agent} />
            <AgentUpdateAction agent={agent} />
          </div>
        }
      />

      {/* Resources */}
      <DetailGrid>
        <StatCard title="CPU" icon={<Cpu className="h-4 w-4" />}>
            <div className="text-xl font-bold text-foreground">
              {agent.resources.availableCPU} / {agent.resources.totalCPU}
            </div>
            <p className="text-sm text-muted-foreground">cores available</p>
        </StatCard>
        <StatCard title="Memory" icon={<MemoryStick className="h-4 w-4" />}>
            <div className="text-xl font-bold text-foreground">
              {formatCapacity(agent.resources.availableMemory)}
            </div>
            <p className="text-sm text-muted-foreground">
              of {formatCapacity(agent.resources.totalMemory)} available
            </p>
            <p className="text-sm text-muted-foreground">
              {formatCapacity(
                agent.resources.totalMemory - agent.resources.availableMemory
              )}{" "}
              committed to VMs
            </p>
            {reportingVMs.length > 0 && (
              <p className="text-sm text-muted-foreground">
                {formatCapacity(guestUsedBytes)} used in guests (
                {reportingVMs.length}/{agentVMs.length} VMs reporting)
              </p>
            )}
        </StatCard>
        <StatCard title="Disk" icon={<HardDrive className="h-4 w-4" />}>
            <div className="text-xl font-bold text-foreground">
              {formatCapacity(agent.resources.physicalFreeDisk)}
            </div>
            <p className="text-sm text-muted-foreground">
              of {formatCapacity(agent.resources.totalDisk)} physically available
            </p>
            <p className="text-sm text-muted-foreground">
              {formatCapacity(agent.resources.availableDisk)} available for new commitments
            </p>
        </StatCard>
        <StatCard title="Last Heartbeat" icon={<Clock className="h-4 w-4" />}>
            <div className="text-sm font-medium text-foreground">
              {agent.lastHeartbeat
                ? formatDate(agent.lastHeartbeat)
                : "Never"}
            </div>
            <p className="text-sm text-muted-foreground">
              {agent.lastHeartbeat
                ? formatTime(agent.lastHeartbeat)
                : "-"}
            </p>
        </StatCard>
      </DetailGrid>

      {/* Details */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Details
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-muted-foreground">ID</p>
              <p className="text-foreground font-mono">{agent.id}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Version</p>
              <p className="text-foreground flex items-center gap-2">
                {agent.version}
                {agent.updateAvailable && (
                  <Badge
                    variant="outline"
                    className="border-amber-500/50 text-amber-600 dark:text-amber-400"
                  >
                    {agent.targetVersion
                      ? `Update available: ${agent.targetVersion}`
                      : "Update available"}
                  </Badge>
                )}
              </p>
            </div>
            <div>
              <p className="text-muted-foreground">Hostname</p>
              <p className="text-foreground">{agent.hostname}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Registered</p>
              <p className="text-foreground">
                {agent.createdAt ? formatDateTime(agent.createdAt) : "Unknown"}
              </p>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Workloads held or teardowns refused (STR-98); renders nothing normally */}
      <AgentWorkloadSafetyCard agent={agent} />

      {/* Host hardware / platform / OS details */}
      <AgentHostInfoCard agent={agent} />

      {/* Auto-update (issue #434) */}
      <AgentAutoUpdateCard agent={agent} />

      {/* Typed capabilities */}
      {capabilityLabels.length > 0 && (
        <Card className="bg-card border-border">
          <CardHeader>
            <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
              <Activity className="h-5 w-5" />
              Capabilities
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex flex-wrap gap-2">
              {capabilityLabels.map((capability) => (
                <Badge
                  key={capability}
                  variant="outline"
                  className="border-input text-foreground/80"
                >
                  {capability}
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      )}
    </DetailPageShell>
  );
}
