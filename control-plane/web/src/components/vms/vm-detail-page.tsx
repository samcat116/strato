"use client";

import { formatDateTime } from "@/lib/format-time";

import { useState, type ReactNode } from "react";
import Link from "next/link";
import dynamic from "next/dynamic";
import {
  Cpu,
  HardDrive,
  MemoryStick,
  ArrowLeft,
  ChevronDown,
  Network,
  Terminal,
  ScrollText,
  Monitor,
} from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import {
  DetailPageLoading,
  DetailPageMissing,
} from "@/components/ui/detail-page-shell";
import { Button } from "@/components/ui/button";
import { CopyButton } from "@/components/ui/copy-button";
import styles from "./vm-detail-page.module.css";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { DetailQueryError } from "@/components/ui/detail-query-error";
import {
  VMStatusBadge,
  VMActions,
  LogViewer,
  VMVolumesCard,
  VMNetworkCard,
  VMSnapshotsCard,
  VMMetadataCard,
  VMIdentityCard,
} from "@/components/vms";
import { useVM, useInvalidateVMs, usePermissions } from "@/lib/hooks";
import { VMExecSessionsCard } from "@/components/vms/vm-exec-sessions-card";
import { VMGuestAgentCard } from "@/components/vms/vm-guest-agent-card";
import { ConvergenceFailureAlert } from "@/components/workloads/convergence-failure-alert";

// Dynamically import VNCDisplay: noVNC touches `document` while its module is
// evaluated, so it cannot be server-rendered (issue #566).
const VNCDisplay = dynamic(
  () => import("@/components/vms/vnc-display").then((mod) => mod.VNCDisplay),
  {
    ssr: false,
    loading: () => (
      <div className="h-[500px] bg-background rounded-lg flex items-center justify-center">
        <p className="text-muted-foreground">Loading display...</p>
      </div>
    ),
  }
);

// Dynamically import ConsoleTerminal to avoid SSR issues with xterm.js
const ConsoleTerminal = dynamic(
  () =>
    import("@/components/terminal/console-terminal").then(
      (mod) => mod.ConsoleTerminal
    ),
  {
    ssr: false,
    loading: () => (
      <div className="h-[500px] bg-background rounded-lg flex items-center justify-center">
        <p className="text-muted-foreground">Loading console...</p>
      </div>
    ),
  }
);

const GuestTerminal = dynamic(
  () => import("@/components/terminal/guest-terminal").then((mod) => mod.GuestTerminal),
  { ssr: false, loading: () => <p>Loading terminal...</p> }
);

function SecondarySection({
  title,
  description,
  children,
}: {
  title: string;
  description: ReactNode;
  children: ReactNode;
}) {
  return (
    <details className="group min-w-0 rounded-lg border bg-card">
      <summary className="flex cursor-pointer list-none items-center gap-3 rounded-lg p-4 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring [&::-webkit-details-marker]:hidden">
        <span className="min-w-0 flex-1">
          <span className="block font-medium">{title}</span>
          <span className="mt-1 block text-xs text-muted-foreground">{description}</span>
        </span>
        <ChevronDown
          aria-hidden="true"
          className="size-4 shrink-0 text-muted-foreground transition-transform group-open:rotate-180 motion-reduce:transition-none"
        />
      </summary>
      <div className={styles.secondaryContent}>{children}</div>
    </details>
  );
}

export function VMDetailPage({ id }: { id: string }) {
  const [activeTab, setActiveTab] = useState("overview");
  const { data: vm, isLoading, error, refetch } = useVM(id);
  const invalidateVMs = useInvalidateVMs();
  const { permissions } = usePermissions([
    { key: "exec", action: "vm:exec", node: { type: "virtual_machine", id } },
  ]);

  if (!id) {
    return (
      <DetailPageMissing message="No VM ID provided" backHref="/vms" backLabel="Back to VMs" />
    );
  }

  if (isLoading) {
    return <DetailPageLoading />;
  }

  if (error || !vm) {
    return (
      <DetailQueryError
        resourceName="VM"
        backHref="/vms"
        backLabel="Back to VMs"
        error={error}
        onRetry={() => void refetch()}
      />
    );
  }

  const isRunning = vm.status === "Running";
  const supportsConsole = vm.hypervisorType !== "apple_virtualization";
  const canUseConsole = supportsConsole && isRunning;
  const consoleUnavailableReason = supportsConsole
    ? "Start the VM to access the console"
    : "Serial console is not supported by Apple Virtualization.";
  const memoryUsagePercent = vm.guestMemoryUsedBytes != null && vm.memory > 0
    ? Math.min(100, Math.max(0, Math.round((vm.guestMemoryUsedBytes / vm.memory) * 100)))
    : null;

  return (
    <div className="min-w-0 w-full space-y-4">
      <header className="space-y-3">
        <Link
          href="/vms"
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft aria-hidden="true" className="size-4" /> Back to VMs
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 space-y-1">
            <div className="flex flex-wrap items-center gap-3">
              <h1 className="break-all text-2xl font-semibold tracking-tight">
                {vm.name}
              </h1>
              <VMStatusBadge status={vm.status} vmId={vm.id} />
            </div>
            {vm.description && (
              <p className="break-words text-sm text-muted-foreground">{vm.description}</p>
            )}
            <div className="flex items-center gap-1 text-xs text-muted-foreground">
              <span className="shrink-0">VM ID</span>
              <code className="min-w-0 break-all">{vm.id}</code>
              <CopyButton value={vm.id} label="Copy VM ID" />
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <Button
              size="sm"
              disabled={!canUseConsole}
              onClick={() => setActiveTab("console")}
              title={!canUseConsole ? consoleUnavailableReason : undefined}
            >
              <Terminal aria-hidden="true" className="size-4" /> Open console
            </Button>
            <div className="border-l pl-2">
              <VMActions vm={vm} onActionComplete={invalidateVMs} />
            </div>
          </div>
        </div>
      </header>

      <ConvergenceFailureAlert conditions={vm.conditions} />

      <Tabs
        value={activeTab}
        onValueChange={setActiveTab}
        className="min-w-0 w-full gap-0"
      >
        <div className="overflow-x-auto border-b pb-3">
          <TabsList aria-label="VM views" className="h-10 bg-card border">
            <TabsTrigger
              value="overview"
              className="data-[state=active]:bg-muted"
            >
              Overview
            </TabsTrigger>
            <TabsTrigger
              value="console"
              className="data-[state=active]:bg-muted"
              disabled={!canUseConsole}
              title={!canUseConsole ? consoleUnavailableReason : undefined}
            >
              <Terminal aria-hidden="true" className="hidden size-4 sm:block" />
              Console
              {!canUseConsole && (
                <span className="sr-only sm:not-sr-only sm:ml-1 sm:text-xs sm:text-muted-foreground">
                  {supportsConsole ? "(VM not running)" : "(Unsupported)"}
                </span>
              )}
            </TabsTrigger>
            {permissions.exec && (
              <TabsTrigger value="exec" className="data-[state=active]:bg-muted">
                <Terminal aria-hidden="true" className="hidden size-4 sm:block" />
                Exec
              </TabsTrigger>
            )}
            {/* The display needs both a running VM and a VM that was created
                with one — headless is the default, and it cannot be changed
                afterwards, so the hint says which condition failed. */}
            <TabsTrigger
              value="display"
              className="data-[state=active]:bg-muted"
              disabled={!isRunning || !vm.graphicsConsole}
            >
              <Monitor aria-hidden="true" className="hidden size-4 sm:block" />
              Display
              {!vm.graphicsConsole ? (
                <span className="sr-only sm:not-sr-only sm:ml-1 sm:text-xs sm:text-muted-foreground">(no display)</span>
              ) : !isRunning ? (
                <span className="sr-only sm:not-sr-only sm:ml-1 sm:text-xs sm:text-muted-foreground">(VM not running)</span>
              ) : null}
            </TabsTrigger>
            <TabsTrigger
              value="logs"
              className="data-[state=active]:bg-muted"
            >
              <ScrollText aria-hidden="true" className="hidden size-4 sm:block" />
              Logs
            </TabsTrigger>
          </TabsList>
        </div>

        <TabsContent value="overview" className={`mt-4 space-y-4 ${styles.panels}`}>
          <section
            aria-label="Compute and connectivity"
            className="grid min-w-0 grid-cols-2 overflow-hidden rounded-lg border bg-card xl:grid-cols-4"
          >
            <div className="border-b border-r p-4 xl:border-b-0">
              <h2 className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
                <Cpu aria-hidden="true" className="size-4" /> CPU
              </h2>
              <p className="mt-2 text-xl font-semibold tabular-nums">
                {vm.cpu}{" "}
                <span className="text-sm font-normal text-muted-foreground">/ {vm.maxCpu} cores</span>
              </p>
            </div>
            <div className="border-b p-4 xl:border-b-0 xl:border-r">
              <h2 className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
                <MemoryStick aria-hidden="true" className="size-4" /> Memory
              </h2>
              <p className="mt-2 text-xl font-semibold tabular-nums">{vm.memoryFormatted}</p>
              {vm.guestMemoryUsedFormatted != null && vm.guestMemoryUsedBytes != null && (
                <>
                  <p className="mt-1 text-xs text-muted-foreground">{vm.guestMemoryUsedFormatted} used in guest</p>
                  {memoryUsagePercent != null && (
                    <div
                      className="mt-2 h-1 w-full rounded-full bg-muted"
                      role="progressbar"
                      aria-label="Guest memory usage"
                      aria-valuenow={memoryUsagePercent}
                      aria-valuemin={0}
                      aria-valuemax={100}
                    >
                      <div
                        className="h-1 rounded-full bg-blue-600"
                        style={{ width: `${memoryUsagePercent}%` }}
                      />
                    </div>
                  )}
                </>
              )}
              {vm.balloonTargetFormatted != null && (
                <p className="mt-1 text-xs text-muted-foreground">
                  Limited to {vm.balloonTargetFormatted}
                  {vm.guestMemoryBalloonActualBytes != null &&
                    vm.balloonTarget != null &&
                    vm.guestMemoryBalloonActualBytes > vm.balloonTarget && " (reclaiming…)"}
                </p>
              )}
            </div>
            <div className="border-r p-4">
              <h2 className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
                <HardDrive aria-hidden="true" className="size-4" /> System disk
              </h2>
              <p className="mt-2 text-xl font-semibold tabular-nums">{vm.diskFormatted}</p>
              <div className="mt-1 break-words text-xs text-muted-foreground">
                {vm.imageId && vm.projectId ? (
                  <Link
                    href={`/images/${vm.projectId}/${vm.imageId}`}
                    className="text-blue-600 hover:underline"
                  >
                    {vm.image}
                  </Link>
                ) : vm.image}
              </div>
            </div>
            <div className="min-w-0 p-4">
              <h2 className="flex items-center gap-2 text-xs font-medium text-muted-foreground">
                <Network aria-hidden="true" className="size-4" /> Network
              </h2>
              <p className="mt-2 text-xl font-semibold tabular-nums">
                {vm.networkInterfaces?.length ?? 0}{" "}
                <span className="text-sm font-normal text-muted-foreground">
                  {vm.networkInterfaces?.length === 1 ? "interface" : "interfaces"}
                </span>
              </p>
              <p className="mt-1 text-xs text-muted-foreground">Assigned and guest addresses below</p>
            </div>
          </section>

          <VMNetworkCard vm={vm} />
          <VMVolumesCard vm={vm} />
          <VMSnapshotsCard vm={vm} />

          <section aria-labelledby="configuration-heading" className="rounded-lg border bg-card p-4">
            <h2 id="configuration-heading" className="mb-3 text-sm font-semibold">Configuration</h2>
            <dl className="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2 xl:grid-cols-3">
              <div className="min-w-0">
                <dt className="text-xs text-muted-foreground">Hypervisor</dt>
                <dd className="mt-1 break-all font-mono">
                  {vm.hypervisorId ? (
                    <Link href={`/agents/${vm.hypervisorId}`} className="text-blue-600 hover:underline">
                      {vm.hypervisorId}
                    </Link>
                  ) : "Unassigned"}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Firmware</dt>
                <dd className="mt-1">
                  {[vm.secureBoot ? "Secure Boot" : null, vm.tpmEnabled ? "TPM 2.0" : null]
                    .filter(Boolean)
                    .join(" + ") || "Standard UEFI"}
                </dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Resource class</dt>
                <dd className="mt-1">
                  <span className="capitalize">{vm.resourceClassKind ?? "guaranteed"}</span>
                  <span className="text-muted-foreground">
                    {" · "}{vm.resourceClass ? `Revision ${vm.resourceClass.revision}` : "Immutable default · 1:1"}
                  </span>
                </dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Instance metadata</dt>
                {/* Older control planes omit this field when it cannot be switched off. */}
                <dd className="mt-1">{vm.metadataEnabled !== false ? "Enabled" : "Disabled"}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Created</dt>
                <dd className="mt-1">{formatDateTime(vm.createdAt)}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">Last updated</dt>
                <dd className="mt-1">{formatDateTime(vm.updatedAt)}</dd>
              </div>
            </dl>
          </section>

          <div className="grid items-start gap-3 xl:grid-cols-3">
            <SecondarySection title="Instance identity" description="Principal and project access">
              <VMIdentityCard vm={vm} />
            </SecondarySection>
            <SecondarySection
              title="Instance metadata"
              description={`${Object.keys(vm.tags ?? {}).length} tags · ${vm.sshAuthorizedKeys?.length ?? 0} SSH keys`}
            >
              <VMMetadataCard vm={vm} onUpdated={invalidateVMs} />
            </SecondarySection>
            <SecondarySection
              title="Guest agent"
              description={vm.guestAgentEnabled === true
                ? "Enabled · reachability and setup details"
                : vm.guestAgentEnabled === false
                  ? "Disabled · setup details"
                  : "Opt-in state unavailable"}
            >
              <VMGuestAgentCard vm={vm} />
            </SecondarySection>
          </div>
        </TabsContent>

        <TabsContent value="console" className="mt-4">
          {canUseConsole ? (
            <Card className="bg-background border-border">
              <CardContent className="p-0">
                <ConsoleTerminal
                  vmId={id}
                  className="h-[500px] rounded-lg overflow-hidden"
                />
              </CardContent>
            </Card>
          ) : (
            <Card className="bg-card border-border">
              <CardContent className="py-12 text-center">
                <Terminal className="h-12 w-12 text-muted-foreground mx-auto mb-4" />
                <p className="text-muted-foreground">
                  {supportsConsole ? "Console is only available when the VM is running." : consoleUnavailableReason}
                </p>
                <p className="text-muted-foreground text-sm mt-2">
                  {supportsConsole ? "Start the VM to access the console." : "Use the guest's own network access tools when available."}
                </p>
              </CardContent>
            </Card>
          )}
        </TabsContent>

        <TabsContent value="exec" className="mt-4">
          {permissions.exec && (
            <Card className="bg-background border-border">
              <CardContent className="p-0">
                {!isRunning ? (
                  <p role="status" className="p-6">VM is not running. Start the VM to use Exec.</p>
                ) : vm.guestAgentEnabled !== true ? (
                  <div role="status" className="p-6">
                    {vm.guestAgentEnabled === false ? (
                      <>
                        <p>Strato guest agent channel is disabled for this VM.</p>
                        <p>Recreation is required to enable it. Create a Linux/QEMU VM with the guest agent opt-in; cloud-init installs it at first boot. {supportsConsole ? "Use Console to access this VM." : "Serial console is unavailable for Apple Virtualization."}</p>
                      </>
                    ) : (
                      <>
                        <p>Guest-agent opt-in state is unavailable.</p>
                        <p>Refresh VM details or update the control plane before using Exec. {supportsConsole ? "Console remains available." : "Serial console is unavailable for Apple Virtualization."}</p>
                      </>
                    )}
                  </div>
                ) : (
                  <>
                    <p className="p-3 text-sm text-muted-foreground">
                      Interactive guest terminal. Closing this tab ends the process. Reconnecting starts a new session.
                    </p>
                    <GuestTerminal key={id} resourceId={id} resourceKind="vm" className="h-[500px] rounded-lg overflow-hidden" />
                  </>
                )}
              </CardContent>
            </Card>
          )}
        </TabsContent>

        <TabsContent value="display" className="mt-4">
          {vm.graphicsConsole && isRunning ? (
            <Card className="bg-background border-border">
              <CardContent className="p-0">
                <VNCDisplay
                  vmId={id}
                  className="h-[500px] rounded-lg overflow-hidden"
                />
              </CardContent>
            </Card>
          ) : (
            <Card className="bg-card border-border">
              <CardContent className="py-12 text-center">
                <Monitor className="h-12 w-12 text-muted-foreground mx-auto mb-4" />
                {vm.graphicsConsole ? (
                  <>
                    <p className="text-muted-foreground">
                      The display is only available when the VM is running.
                    </p>
                    <p className="text-muted-foreground text-sm mt-2">
                      Start the VM to access the display.
                    </p>
                  </>
                ) : (
                  <>
                    <p className="text-muted-foreground">
                      This VM was created without a display.
                    </p>
                    <p className="text-muted-foreground text-sm mt-2">
                      The display device is fixed when the VM is created, so it
                      cannot be added later. Create a new VM with the display
                      enabled to use a graphical console.
                    </p>
                  </>
                )}
              </CardContent>
            </Card>
          )}
        </TabsContent>

        <TabsContent value="logs" className="mt-4">
          <LogViewer vmId={id} />
        </TabsContent>
      </Tabs>
      {vm.guestAgentEnabled && (
        <div className={styles.panels}>
          <VMExecSessionsCard vmId={vm.id} />
        </div>
      )}
    </div>
  );
}
