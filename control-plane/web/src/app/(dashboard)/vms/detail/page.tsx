"use client";

import { useSearchParams } from "next/navigation";
import Link from "next/link";
import dynamic from "next/dynamic";
import {
  ArrowLeft,
  Cpu,
  HardDrive,
  MemoryStick,
  Clock,
  Terminal,
  ScrollText,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  VMStatusBadge,
  VMActions,
  LogViewer,
  VMVolumesCard,
  VMNetworkCard,
} from "@/components/vms";
import { useVM, useInvalidateVMs } from "@/lib/hooks";

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

export default function VMDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const { data: vm, isLoading, error } = useVM(id);
  const invalidateVMs = useInvalidateVMs();

  if (!id) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">No VM ID provided</p>
          <Link href="/vms">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to VMs
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-48 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (error || !vm) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">VM not found or failed to load</p>
          <Link href="/vms">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to VMs
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  const isRunning = vm.status === "Running";

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <Link
            href="/vms"
            className="text-sm text-muted-foreground hover:text-foreground flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to VMs
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-foreground">{vm.name}</h2>
            <VMStatusBadge status={vm.status} vmId={vm.id} />
          </div>
          {vm.description && (
            <p className="text-muted-foreground mt-1">{vm.description}</p>
          )}
        </div>
        <VMActions vm={vm} onActionComplete={invalidateVMs} />
      </div>

      {/* Tabs */}
      <Tabs defaultValue="overview" className="w-full">
        <TabsList className="bg-card border-border">
          <TabsTrigger
            value="overview"
            className="data-[state=active]:bg-muted"
          >
            Overview
          </TabsTrigger>
          <TabsTrigger
            value="console"
            className="data-[state=active]:bg-muted"
            disabled={!isRunning}
          >
            <Terminal className="h-4 w-4 mr-2" />
            Console
            {!isRunning && (
              <span className="ml-2 text-xs text-muted-foreground">(VM not running)</span>
            )}
          </TabsTrigger>
          <TabsTrigger
            value="logs"
            className="data-[state=active]:bg-muted"
          >
            <ScrollText className="h-4 w-4 mr-2" />
            Logs
          </TabsTrigger>
        </TabsList>

        <TabsContent value="overview" className="space-y-6 mt-6">
          {/* Resources */}
          <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <Cpu className="h-4 w-4" />
                  CPU
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {vm.cpu} / {vm.maxCpu}
                </div>
                <p className="text-sm text-muted-foreground">cores</p>
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <MemoryStick className="h-4 w-4" />
                  Memory
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {vm.memoryFormatted}
                </div>
                {/* Guest-reported usage (virtio-balloon); absent until the
                    guest's balloon driver reports. */}
                {vm.guestMemoryUsedFormatted != null &&
                  vm.guestMemoryUsedBytes != null && (
                    <>
                      <p className="text-sm text-muted-foreground">
                        {vm.guestMemoryUsedFormatted} used in guest
                      </p>
                      <div
                        className="mt-2 h-1.5 w-full rounded-full bg-muted"
                        role="progressbar"
                        aria-label="Guest memory usage"
                        aria-valuenow={Math.round(
                          (vm.guestMemoryUsedBytes / vm.memory) * 100
                        )}
                        aria-valuemin={0}
                        aria-valuemax={100}
                      >
                        <div
                          className="h-1.5 rounded-full bg-blue-600"
                          style={{
                            width: `${Math.min(
                              100,
                              Math.round(
                                (vm.guestMemoryUsedBytes / vm.memory) * 100
                              )
                            )}%`,
                          }}
                        />
                      </div>
                    </>
                  )}
                {/* Operator balloon target (issue #567 phase 2): what the
                    guest is being held to, and — while the guest is still
                    handing pages back — how far the balloon has got. */}
                {vm.balloonTargetFormatted != null && (
                  <p className="mt-2 text-sm text-muted-foreground">
                    Limited to {vm.balloonTargetFormatted}
                    {vm.guestMemoryBalloonActualBytes != null &&
                      vm.balloonTarget != null &&
                      vm.guestMemoryBalloonActualBytes >
                        vm.balloonTarget && " (reclaiming…)"}
                  </p>
                )}
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <HardDrive className="h-4 w-4" />
                  Disk
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {vm.diskFormatted}
                </div>
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <Clock className="h-4 w-4" />
                  Created
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-sm font-medium text-foreground">
                  {new Date(vm.createdAt).toLocaleDateString()}
                </div>
                <p className="text-sm text-muted-foreground">
                  {new Date(vm.createdAt).toLocaleTimeString()}
                </p>
              </CardContent>
            </Card>
          </div>

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
                  <p className="text-foreground font-mono">{vm.id}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">Image</p>
                  {vm.imageId && vm.projectId ? (
                    <Link
                      href={`/images/detail?id=${vm.imageId}&projectId=${vm.projectId}`}
                      className="text-blue-600 hover:text-blue-700 hover:underline"
                    >
                      {vm.image}
                    </Link>
                  ) : (
                    <p className="text-foreground">{vm.image}</p>
                  )}
                </div>
                <div>
                  <p className="text-muted-foreground">Hypervisor</p>
                  {vm.hypervisorId ? (
                    <Link
                      href={`/agents/detail?id=${vm.hypervisorId}`}
                      className="text-blue-600 hover:text-blue-700 hover:underline font-mono"
                    >
                      {vm.hypervisorId}
                    </Link>
                  ) : (
                    <p className="text-foreground">Unassigned</p>
                  )}
                </div>
                <div>
                  <p className="text-muted-foreground">Firmware</p>
                  <p className="text-foreground">
                    {[
                      vm.secureBoot ? "Secure Boot" : null,
                      vm.tpmEnabled ? "TPM 2.0" : null,
                    ]
                      .filter(Boolean)
                      .join(" + ") || "Standard UEFI"}
                  </p>
                </div>
                <div>
                  <p className="text-muted-foreground">Last Updated</p>
                  <p className="text-foreground">
                    {new Date(vm.updatedAt).toLocaleString()}
                  </p>
                </div>
              </div>
            </CardContent>
          </Card>

          {/* Attached volumes */}
          <VMVolumesCard vm={vm} />

          {/* Network interfaces */}
          <VMNetworkCard vm={vm} />
        </TabsContent>

        <TabsContent value="console" className="mt-6">
          {isRunning ? (
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
                  Console is only available when the VM is running.
                </p>
                <p className="text-muted-foreground text-sm mt-2">
                  Start the VM to access the console.
                </p>
              </CardContent>
            </Card>
          )}
        </TabsContent>

        <TabsContent value="logs" className="mt-6">
          <LogViewer vmId={id} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
